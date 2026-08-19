defmodule AshEnterprise.AI.InterpreterKeyTest do
  @moduledoc """
  What the helper console says when no provider key is usable.

  This is the state a fresh checkout is in, so the message it produces is the
  first thing a new contributor reads about the agent flow. It should say that
  nothing is configured and name the variable to set — not surface a provider's
  internal complaint.

  The distinction is not cosmetic. `.env.example` ships `ANTHROPIC_API_KEY=` with
  nothing after it, and `ReqLLM.Keys.get/1` *finds* that variable and reports the
  provider as configured. The request then goes out and fails with
  "ANTHROPIC_API_KEY was found but is empty", which reads like a broken key rather
  than an absent one and sends people looking in the wrong place.
  """

  use ExUnit.Case, async: false

  alias AshEnterprise.AI.Interpreter

  setup do
    previous_env = System.get_env("ANTHROPIC_API_KEY")
    previous_config = Application.get_env(:ash_enterprise, :ai)

    # Pin the model so the assertion does not depend on which provider key the
    # machine running the suite happens to have.
    Application.put_env(:ash_enterprise, :ai,
      interpreter_model: "anthropic:claude-haiku-4-5-20251001"
    )

    on_exit(fn ->
      if previous_config,
        do: Application.put_env(:ash_enterprise, :ai, previous_config),
        else: Application.delete_env(:ash_enterprise, :ai)

      if previous_env,
        do: System.put_env("ANTHROPIC_API_KEY", previous_env),
        else: System.delete_env("ANTHROPIC_API_KEY")
    end)

    :ok
  end

  describe "a key that is set but blank" do
    for {label, value} <- [{"empty", ""}, {"whitespace only", "   \n"}] do
      test "#{label} reads as unconfigured, not as a provider error" do
        System.put_env("ANTHROPIC_API_KEY", unquote(value))

        assert {:error, message} = Interpreter.interpret("show me the legacy users", nil, nil)

        # The message written for this situation...
        assert message =~ "No API key is configured"
        # ...naming the variable the *configured* model actually needs.
        assert message =~ "ANTHROPIC_API_KEY"
        # ...and not ReqLLM's complaint about a key it found.
        refute message =~ "found but is empty"
      end
    end

    test "it also says the rest of the flow does not need a provider" do
      System.put_env("ANTHROPIC_API_KEY", "")

      assert {:error, message} = Interpreter.interpret("anything", nil, nil)

      # Worth stating, because the natural conclusion from "no API key" is that
      # none of this works without one, and only interpretation does not.
      assert message =~ "does not depend on a provider"
    end
  end

  test "a key with real content gets past the configuration check" do
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-not-a-real-key")

    # Reaching the provider is the point: whatever comes back, it is no longer
    # the "nothing is configured" answer. The call itself will fail on a bogus
    # key, and that failure is the provider's to report.
    case Interpreter.interpret("show me the legacy users", nil, nil) do
      {:error, message} -> refute message =~ "No API key is configured"
      {:ok, _plan} -> :ok
    end
  end
end
