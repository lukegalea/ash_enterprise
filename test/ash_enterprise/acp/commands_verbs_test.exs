defmodule AshEnterprise.Acp.CommandsVerbsTest do
  @moduledoc """
  The prompt grammar's acts beyond approve and reject (AGT-54): asking the requester,
  answering, the recovery acts and the request doors, each routed without a model to the
  action `AshEnterprise.Acp.Commands.verbs/0` names, and asking first where its effects
  declaration says so. The words a person types are kept as typed.

  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: true

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshEnterprise.Acp.Commands
  alias AshEnterprise.Execution.{Intervention, Invocation, ReleaseManifest}

  setup do
    admin = tenant!()
    %{actor: admin.actor}
  end

  defp confirms(route) do
    assert {:ok, %{spec: %{resource: Invocation, action: :confirm, inputs: inputs}}} = route
    inputs
  end

  test "retry, cancel and reconcile ask first, and keep the reason as typed", %{actor: actor} do
    id = Ecto.UUID.generate()

    inputs = confirms(Commands.route("retry #{id} The Lab Sent It Twice", actor))
    assert inputs.target == AshAgent.Invocation.Target.name(Intervention, :rerun)
    assert inputs.args == %{"invocation_id" => id, "reason" => "The Lab Sent It Twice"}

    inputs = confirms(Commands.route("cancel #{id} Not Needed", actor))
    assert inputs.target == AshAgent.Invocation.Target.name(Intervention, :cancel)

    inputs = confirms(Commands.route("reconcile #{id} succeeded The registry has it", actor))
    assert inputs.target == AshAgent.Invocation.Target.name(Intervention, :resolve)
    assert inputs.args["resolution"] == "succeeded"
    assert inputs.args["reason"] == "The registry has it"
  end

  test "a recovery act needs an invocation id, and reconcile needs a known resolution", %{
    actor: actor
  } do
    assert {:error, _} = Commands.route("retry tomorrow because", actor)
    assert {:error, _} = Commands.route("reconcile #{Ecto.UUID.generate()} maybe why", actor)
  end

  test "ask and answer need a numbered task from the approvals list", %{actor: actor} do
    assert {:error, message} = Commands.route("ask 7 Which lab?", actor)
    assert message =~ "no approval #7"
    assert {:error, _} = Commands.route("answer 1 The city lab", actor)
  end

  test "release routes to the request door, by id", %{actor: actor} do
    id = Ecto.UUID.generate()

    assert {:ok, %{spec: spec}} = Commands.route("release #{id}", actor)

    case spec do
      %{resource: ReleaseManifest, action: :request_release, inputs: inputs} ->
        assert inputs.record_id == id

      %{resource: Invocation, action: :confirm, inputs: inputs} ->
        assert inputs.target == AshAgent.Invocation.Target.name(ReleaseManifest, :request_release)
    end

    assert {:error, _} = Commands.route("release the latest", actor)
  end

  test "grant names a role and a person the actor may read, or says why not", %{actor: actor} do
    assert {:error, _} = Commands.route("grant No Such Role to nobody@clinic.example", actor)
  end
end
