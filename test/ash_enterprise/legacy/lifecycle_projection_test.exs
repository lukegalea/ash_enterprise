defmodule AshEnterprise.Legacy.LifecycleProjectionTest do
  @moduledoc """
  `Legacy.User.lifecycle_status` is a read-only projection of the legacy application's
  `state`. It is not a lifecycle this application runs.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Accounts.ProjectedUser
  alias AshEnterprise.Legacy.User
  alias AshEnterprise.Platform.Lifecycle
  alias AshStrangler.Verifiers.VerifyStateMachineBacked

  test "the read model carries no state machine and no write action" do
    refute AshStateMachine in Spark.extensions(User)

    assert for(%{type: type} <- Ash.Resource.Info.actions(User), uniq: true, do: type) == [:read]
  end

  test "the status is declared in the platform's vocabulary and mapped read-only" do
    attribute = Ash.Resource.Info.attribute(User, :lifecycle_status)
    assert attribute.public?
    refute attribute.allow_nil?
    assert attribute.constraints[:one_of] == Lifecycle.statuses()

    mapping =
      Enum.find(
        AshStrangler.Info.source(User).mappings,
        &(Map.get(&1, :attribute) == :lifecycle_status)
      )

    assert %AshStrangler.Map{read_only?: true, because: because} = mapping
    assert because =~ "Lossy"
  end

  test "the public surface is the platform's, so the view's columns do not move" do
    calculations = Enum.map(Ash.Resource.Info.calculations(User), & &1.name)
    assert :status_code in calculations
    assert :state_code in calculations

    names = Enum.map(Ash.Resource.Info.attributes(User), & &1.name)

    assert Enum.find_index(names, &(&1 == :lifecycle_status)) <
             Enum.find_index(names, &(&1 == :version_number))
  end

  test "state_machine?: false is refused on anything but a read-only projection" do
    dsl =
      Spark.Dsl.Transformer.set_option(
        AshEnterprise.Accounts.ProjectedUser.spark_dsl_config(),
        [:platform],
        :state_machine?,
        false
      )

    assert {:error, error} = AshEnterprise.Platform.Verifiers.ProjectedLifecycle.verify(dsl)
    assert Exception.message(error) =~ "read-only strangler"
  end

  test "the strangler's state-machine rule holds with nothing excluded" do
    assert :ok = VerifyStateMachineBacked.verify(User.spark_dsl_config())
  end

  test "the owned projection keeps the platform's machine" do
    assert AshStateMachine in Spark.extensions(ProjectedUser)
    assert Ash.Resource.Info.action(ProjectedUser, :deactivate)
  end
end
