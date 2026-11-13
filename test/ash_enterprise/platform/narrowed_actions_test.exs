defmodule AshEnterprise.Platform.NarrowedActionsTest do
  @moduledoc """
  ADR 0059's compile-time guards: `human_only:`, `machinery_only:` and `engine_only:` must name
  real actions and must not contradict each other or `self_service:`, and a
  strangled read model that projects `version_number` as a constant must keep
  the platform's optimistic lock off its writes. That last check is
  `ash_strangler`'s (`VerifyOptimisticLock`); the cases here run it over this
  application's resources.

  The verifiers run on a real resource's DSL with one option changed, the way
  the Nango edge tests its verifier: a resource defined in a test would fail
  in the compiler's checker, not in the test.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Conformance.Widget
  alias AshEnterprise.Legacy.User, as: LegacyUser
  alias AshEnterprise.Platform.Verifiers.NarrowedActions
  alias AshStrangler.Verifiers.VerifyOptimisticLock
  alias Spark.Dsl.Transformer

  defp widget(changes) do
    Enum.reduce(changes, Widget.spark_dsl_config(), fn {option, value}, dsl ->
      Transformer.set_option(dsl, [:platform], option, value)
    end)
  end

  defp refusal(verifier, dsl) do
    assert {:error, %Spark.Error.DslError{message: message}} = verifier.verify(dsl)
    message
  end

  describe "NarrowedActions" do
    test "the conformance widget's declarations are well formed" do
      assert :ok = NarrowedActions.verify(Widget.spark_dsl_config())
    end

    test "a misspelt human_only action is refused" do
      assert refusal(NarrowedActions, widget(human_only: [:aprove])) =~
               "human_only :aprove: no such action"
    end

    test "a misspelt machinery_only action is refused" do
      assert refusal(NarrowedActions, widget(machinery_only: [:clam])) =~
               "machinery_only :clam: no such action"
    end

    test "a misspelt changes_authority action is refused" do
      assert refusal(NarrowedActions, widget(changes_authority: [:asign])) =~
               "changes_authority :asign: no such action"
    end

    test "an action cannot be both human-only and machinery-only" do
      assert refusal(NarrowedActions, widget(human_only: [:approve, :claim])) =~
               "machinery_only :claim is both human_only and machinery_only"
    end

    test "a misspelt engine_only action is refused" do
      assert refusal(NarrowedActions, widget(engine_only: [:creat])) =~
               "engine_only :creat: no such action"
    end

    test "an engine-only action cannot also be human-only, machinery-only or self-service" do
      for {action, label} <- [
            approve: "human_only",
            claim: "machinery_only",
            mine: "self_service"
          ] do
        assert refusal(NarrowedActions, widget(engine_only: [action])) =~
                 "engine_only #{inspect(action)} is also #{label}"
      end
    end

    test "a machinery-only action cannot also be self-service" do
      assert refusal(NarrowedActions, widget(self_service: [:mine, :whoami, :claim])) =~
               "machinery_only :claim is machinery_only and self_service"
    end
  end

  describe "the optimistic lock on a strangled read model" do
    # The widget's update action and the lock `Platform.Resource` puts on every
    # update, added to a DSL that lacks them.
    defp with_platform_lock(dsl) do
      update = Widget |> Ash.Resource.Info.actions() |> Enum.find(&(&1.type == :update))

      lock =
        Widget
        |> Ash.Resource.Info.changes()
        |> Enum.find(&match?({Ash.Resource.Change.OptimisticLock, _}, &1.change))

      {update.name,
       dsl
       |> Transformer.add_entity([:actions], update)
       |> Transformer.add_entity([:changes], lock)}
    end

    test "the extension the read models are strangled with carries the check" do
      assert AshStrangler.Resource in Spark.extensions(LegacyUser)
      assert VerifyOptimisticLock in AshStrangler.Resource.verifiers()
    end

    test "Legacy.User, which opts out of the lock, passes" do
      refute Spark.Dsl.Extension.get_opt(LegacyUser, [:platform], :optimistic_lock?, true)
      assert :ok = VerifyOptimisticLock.verify(LegacyUser.spark_dsl_config())
    end

    test "Legacy.User with an update carrying the platform's lock is refused" do
      {action, dsl} = with_platform_lock(LegacyUser.spark_dsl_config())

      assert refusal(VerifyOptimisticLock, dsl) =~
               "action #{inspect(action)} locks on :version_number"
    end

    test "an ordinary resource keeps the lock and passes" do
      assert :ok = VerifyOptimisticLock.verify(Widget.spark_dsl_config())
    end
  end
end
