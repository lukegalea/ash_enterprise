defimpl AshAgent.FailureClass, for: AshOperations.Error do
  @moduledoc """
  How a declared operation's failure classifies a governed invocation. The battery's own
  copy of the host's impl, because the battery is its own instantiation:

    * `:ambiguous` is `:indeterminate`: the call may have happened, so the invocation is
      left `outcome_unknown` and reconciled, never re-sent.
    * `:rate_limited`, `:timeout`, `:server_error` and `:transport` are `:transient`.
    * `:disclosure_refused` is `:denied`, with the gate's code: nothing was sent.
    * Everything else is `:permanent` under its own reason.
  """

  def classify(%{reason: :ambiguous}), do: {:indeterminate, "ambiguous"}

  def classify(%{reason: reason})
      when reason in [:rate_limited, :timeout, :server_error, :transport],
      do: {:transient, Atom.to_string(reason)}

  def classify(%{reason: :disclosure_refused, provider_code: code}),
    do: {:denied, code || "disclosure_refused"}

  def classify(%{reason: reason}), do: {:permanent, to_string(reason)}
end
