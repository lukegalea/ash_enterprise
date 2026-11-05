defimpl AshAgent.FailureClass, for: AshEnterprise.Credentialing.RegistryError do
  @moduledoc """
  How a registry failure (`AshEnterprise.Credentialing.RegistryError`) classifies an
  activation's invocation (`AshAgent.Invocation.Failure`).

    * `:unavailable` is `:transient`: the registry was not reached, so nothing was
      activated and the invocation may try again after a backoff.
    * `:refused` is `:permanent`: the registry answered no, and asking again would
      change nothing.
  """

  def classify(%{reason: :unavailable}), do: {:transient, "registry_unavailable"}
  def classify(%{reason: :refused}), do: {:permanent, "registry_refused"}
end
