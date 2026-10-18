defmodule AshEnterprise.Mdm.StewardReviewBaselineTest do
  @moduledoc """
  `DemoData.publish_steward_review!/0` publishes the checked-in steward-review
  BPMN once and then only when the file changes: seeding a tenant or
  populating the demo must not stack up identical baseline versions.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Bpmn.Definition
  alias AshEnterprise.Mdm.DemoData
  alias AshEnterprise.Platform.Seeder

  setup do
    AshEnterprise.Process.Resolver.forget_platform_tenant()
    on_exit(&AshEnterprise.Process.Resolver.forget_platform_tenant/0)
    :ok
  end

  test "an unchanged file publishes nothing the second time" do
    first = DemoData.publish_steward_review!()
    assert first == :unchanged or match?({:published, _}, first)

    assert DemoData.publish_steward_review!() == :unchanged
    assert DemoData.publish_steward_review!() == :unchanged

    platform = Seeder.seed_platform_organization()

    versions =
      Definition
      |> Ash.Query.filter(key == "mdm.steward_review")
      |> Ash.read!(tenant: platform.id, authorize?: false)

    assert length(versions) == 1
  end

  test "ensuring the baselines publishes the band table and the process once each" do
    assert %{bands: :published} = AshEnterprise.Mdm.Baselines.ensure!()

    assert %{bands: :published, steward_review: :unchanged} =
             AshEnterprise.Mdm.Baselines.ensure!()

    platform = Seeder.seed_platform_organization()

    bands =
      AshEnterprise.Decisions.Definition
      |> Ash.Query.filter(key == "mdm:match_bands" and status == :published)
      |> Ash.read!(tenant: platform.id, authorize?: false)

    assert length(bands) == 1
    assert {:ok, :review} = AshEnterprise.Mdm.Banding.band(0.6, platform.id)
  end
end
