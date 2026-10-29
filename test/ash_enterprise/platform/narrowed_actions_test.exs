defmodule AshEnterprise.Platform.NarrowedActionsTest do
  @moduledoc """
  ADR 0059's compile-time guards: `human_only:` and `machinery_only:` must name
  real actions and must not contradict each other or `self_service:`, and a
  strangled read model that projects `version_number` as a constant must opt
  out of the optimistic lock.

  The verifiers run on a real resource's DSL with one option changed, the way
  the Nango edge tests its verifier: a resource defined in a test would fail
  in the compiler's checker, not in the test.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Conformance.Widget
  alias AshEnterprise.Platform.Verifiers.NarrowedActions
  alias AshEnterprise.Platform.Verifiers.OptimisticLock
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

    test "an action cannot be both human-only and machinery-only" do
      assert refusal(NarrowedActions, widget(human_only: [:approve, :claim])) =~
               "machinery_only :claim is both human_only and machinery_only"
    end

    test "a machinery-only action cannot also be self-service" do
      assert refusal(NarrowedActions, widget(self_service: [:mine, :whoami, :claim])) =~
               "machinery_only :claim is machinery_only and self_service"
    end
  end

  describe "OptimisticLock" do
    test "a strangled read model that projects version_number opts out, and passes" do
      assert :ok = OptimisticLock.verify(AshEnterprise.Legacy.User.spark_dsl_config())
    end

    test "the same read model with the lock left on is refused" do
      dsl =
        Transformer.set_option(
          AshEnterprise.Legacy.User.spark_dsl_config(),
          [:platform],
          :optimistic_lock?,
          true
        )

      assert refusal(OptimisticLock, dsl) =~ "set `optimistic_lock?: false`"
    end

    test "an ordinary resource keeps the lock and passes" do
      assert :ok = OptimisticLock.verify(Widget.spark_dsl_config())
    end
  end
end
