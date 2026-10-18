defmodule AshEnterprise.Mdm.Baselines do
  @moduledoc """
  The platform baselines entity resolution needs before it can route a pair:
  the seed band table `mdm:match_bands` (`AshEnterprise.Mdm.Banding`) and the
  steward-review process `mdm.steward_review`, both published into the
  platform organization, which tenants inherit from (ADR 0054).

  Without them a sweep matches but cannot band: every pair is left pending
  and unbanded, and the steward queue stays empty. So turning a source on
  (`mix ash_enterprise.mdm.people --seed-as`) ensures them first, as the
  demo does. Both are published by the system, not a person: they are the
  platform's defaults, and bands tighten only through calibration.
  """

  require Ash.Query

  alias AshEnterprise.Bpmn.Definition
  alias AshEnterprise.Mdm.Banding
  alias AshEnterprise.Platform.{Seeder, SystemActor}

  @steward_key "mdm.steward_review"

  # Sobelow reads `@sobelow_skip` out of the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see AshEnterprise.Audit.Export).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc "Publishes whichever baseline is missing or changed. Idempotent."
  @spec ensure!() :: %{
          bands: :published,
          steward_review: :unchanged | {:published, pos_integer()}
        }
  def ensure! do
    platform = Seeder.seed_platform_organization()
    _ = Banding.publish_seed_bands!(platform.id)
    %{bands: :published, steward_review: publish_steward_review!()}
  end

  @doc """
  Publishes the checked-in steward-review BPMN as the platform baseline
  `mdm.steward_review`, as a new version when the latest published one's XML
  differs from the file (and as version 1 when there is none). Returns
  `:unchanged` or `{:published, version}`.

  Running instances keep the definition they pinned; new review candidates
  start on the new version — which is how existing tenants pick up a changed
  candidate list or outcome set (the Data Steward candidate, `escalate`).
  """
  @spec publish_steward_review!() :: :unchanged | {:published, pos_integer()}
  def publish_steward_review! do
    platform = Seeder.seed_platform_organization()
    xml = steward_review_xml()

    latest =
      Definition
      |> Ash.Query.filter(key == ^@steward_key and status == :published)
      |> Ash.Query.sort(version: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(tenant: platform.id, authorize?: false)

    # The definition stores its XML trimmed (Ash trims string attributes), so
    # compare trimmed: the file's trailing newline is not a change.
    if latest && String.trim(latest.xml) == String.trim(xml) do
      :unchanged
    else
      published =
        Definition.create!(%{key: @steward_key, name: "MDM steward review", xml: xml},
          actor: SystemActor.process(),
          tenant: platform.id
        )
        |> Definition.publish!(actor: SystemActor.process(), tenant: platform.id)

      {:published, published.version}
    end
  end

  # The path is a constant under this application's own priv dir — no caller
  # input reaches it. Skipped here, by name, so any change that lets a caller
  # choose the file is the thing a reviewer should question.
  @sobelow_skip ["Traversal.FileModule"]
  defp steward_review_xml do
    File.read!(Path.join(:code.priv_dir(:ash_enterprise), "bpmn/mdm_steward_review.bpmn"))
  end
end
