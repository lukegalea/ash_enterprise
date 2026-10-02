defmodule AshEnterprise.Security.AiActorNoBypassTest do
  @moduledoc """
  ADR 0043's code-side guarantee (AST-136): the `ai` system actor is an
  attribution label with no authority. It never matches the `SystemActor`
  bypass — used as a `bypass` at every shared-policy site — and its
  `ActorContext` is empty, so every grant-based check fails closed.

  Pure unit assertions; no database. The other system actors keep their
  bypass, which is what the background machinery relies on.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Security.Checks.SystemActor, as: SystemActorCheck

  describe "the SystemActor bypass check" do
    test "the ai actor never matches" do
      refute SystemActorCheck.match?(SystemActor.ai(), nil, [])
    end

    test "every other system actor still matches" do
      Enum.each(SystemActor.all() -- [SystemActor.ai()], fn actor ->
        assert SystemActorCheck.match?(actor, nil, []),
               "expected #{inspect(actor.name)} to keep the system-actor bypass"
      end)
    end

    test "a system? context still matches (the context-level bypass is unchanged)" do
      assert SystemActorCheck.match?(ActorContext.system(), nil, [])
    end
  end

  describe "the ai actor's context" do
    test "resolves to an empty context: no roles, no grants, not system" do
      context = ActorContext.for_actor(SystemActor.ai(), tenant: Ecto.UUID.generate())

      refute context.system?
      assert context == %ActorContext{}
    end

    test "an ordinary system actor still resolves to the grant-everything context" do
      tenant = Ecto.UUID.generate()

      assert ActorContext.for_actor(SystemActor.oban(), tenant: tenant) ==
               ActorContext.system(tenant)
    end
  end
end
