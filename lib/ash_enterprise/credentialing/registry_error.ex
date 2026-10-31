defmodule AshEnterprise.Credentialing.RegistryError do
  @moduledoc """
  A typed failure from the credential registry (`AshEnterprise.Credentialing.Registry`).

  | `reason` | Meaning |
  |---|---|
  | `:unavailable` | the registry could not be reached; nothing was sent |
  | `:refused` | the registry answered no |

  `AshAgent.FailureClass` classifies it for an invocation
  (`AshEnterprise.Credentialing.RegistryFailure`).
  """

  use Splode.Error, fields: [:reason], class: :unknown

  @type t :: %__MODULE__{reason: :unavailable | :refused}

  @impl true
  def message(%__MODULE__{reason: reason}), do: "credential registry: #{reason}"
end
