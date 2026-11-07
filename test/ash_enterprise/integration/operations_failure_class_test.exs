defmodule AshEnterprise.Integration.OperationsFailureClassTest do
  @moduledoc """
  The one host impl that classifies a declared operation's failure for a governed invocation
  (`AshAgent.FailureClass` for `AshOperations.Error`). The retry table that produces these
  reasons is the `ash_operations` suite's; this is the host's mapping.
  """

  use ExUnit.Case, async: true

  alias AshAgent.FailureClass

  defp error(reason, fields \\ []),
    do: AshOperations.Error.exception([reason: reason, provider: :credential_registry] ++ fields)

  test "an ambiguous call is indeterminate, a refused disclosure is denied, a rate limit is transient" do
    assert FailureClass.classify(error(:ambiguous)) == {:indeterminate, "ambiguous"}

    assert FailureClass.classify(error(:disclosure_refused, provider_code: "residency_denied")) ==
             {:denied, "residency_denied"}

    assert FailureClass.classify(error(:rate_limited, retry_after_ms: 1_000)) ==
             {:transient, "rate_limited"}

    for reason <- [:timeout, :server_error, :transport] do
      assert FailureClass.classify(error(reason)) == {:transient, Atom.to_string(reason)}
    end

    for reason <- [:unauthorized, :forbidden, :not_configured] do
      assert FailureClass.classify(error(reason)) == {:permanent, Atom.to_string(reason)}
    end

    assert FailureClass.classify(error(:unprocessable)) == {:permanent, "unprocessable"}
  end
end
