defimpl AshAgent.FailureClass, for: AshOperations.Error do
  @moduledoc """
  How a declared operation's failure (`AshOperations.Error`) classifies a governed
  invocation (`AshAgent.Invocation.Failure`). One host impl for every provider declared with
  `AshOperations`:

    * `:ambiguous` is `:indeterminate`: the call may have happened, so the invocation is
      left `outcome_unknown` and reconciled, never re-sent.
    * `:rate_limited`, `:timeout`, `:server_error` and `:transport` are `:transient`: on an
      idempotent read, or before anything was sent, so trying again later is safe.
    * `:disclosure_refused` is `:denied`, with the gate's code: nothing was sent.
    * `:unauthorized`, `:forbidden` and `:not_configured` are `:permanent`: the credential or
      the configuration is wrong, which is operations' to fix.
    * Everything else is `:permanent` under its own reason.
  """

  def classify(%{reason: :ambiguous}), do: {:indeterminate, "ambiguous"}

  def classify(%{reason: reason})
      when reason in [:rate_limited, :timeout, :server_error, :transport],
      do: {:transient, Atom.to_string(reason)}

  def classify(%{reason: :disclosure_refused, provider_code: code}),
    do: {:denied, code || "disclosure_refused"}

  def classify(%{reason: reason}) when reason in [:unauthorized, :forbidden, :not_configured],
    do: {:permanent, Atom.to_string(reason)}

  def classify(%{reason: reason}), do: {:permanent, to_string(reason)}
end
