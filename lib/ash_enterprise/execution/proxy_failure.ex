defimpl AshAgent.FailureClass, for: AshEnterprise.Integration.ProxyError do
  @moduledoc """
  How a failure at the provider edge (`AshEnterprise.Integration.ProxyError`) classifies
  an invocation's failure (`AshAgent.Invocation.Failure`).

    * `:rate_limited` is `:transient`: the provider refused before doing anything, so
      the invocation may try again after a backoff.
    * `:server_error`, `:transport` and `:nango_error` are `:indeterminate`: the request
      may have reached the provider and taken effect, and the acknowledgement was lost
      (a 5xx after processing, a timeout, a dropped connection). An idempotent target
      tries again with the same key; any other becomes `outcome_unknown` and is
      reconciled, never sent again blindly.
    * Everything else is `:permanent`: a bad request, a refused or missing credential, a
      provider that answered no. Trying again would change nothing.

  The code is the reason's name, never a body or a message.
  """

  @indeterminate [:server_error, :transport, :nango_error]

  def classify(%{reason: :rate_limited}), do: {:transient, "rate_limited"}

  def classify(%{reason: reason}) when reason in @indeterminate,
    do: {:indeterminate, Atom.to_string(reason)}

  def classify(%{reason: reason}) when is_atom(reason) and not is_nil(reason),
    do: {:permanent, Atom.to_string(reason)}

  def classify(_error), do: {:permanent, "provider_error"}
end
