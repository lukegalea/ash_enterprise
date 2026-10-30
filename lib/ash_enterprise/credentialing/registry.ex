defmodule AshEnterprise.Credentialing.Registry do
  @moduledoc """
  The registry a clinic activates credentials with, and the one module that would speak
  to it (Iron Law #20).

  A stub: there is no registry to call. `activate/1` accepts every activation and
  answers with a reference derived from the credential's id, so the same credential
  always gets the same reference; that is what lets `activate_credential` declare
  itself idempotent. The stub keeps no record of what it accepted, so `lookup/1`
  cannot tell whether an activation happened and answers `:unknown`, which leaves the
  question to a person. A connector that can answer replaces this module.
  """

  @type answer :: %{status: :active | :not_found | :unknown, reference: String.t() | nil}

  @doc "Ask the registry to activate a credential. Returns the registry's reference."
  @spec activate(Ash.UUID.t()) :: {:ok, String.t()}
  def activate(credential_id) when is_binary(credential_id),
    do: {:ok, reference(credential_id)}

  @doc "Ask the registry whether it activated a credential."
  @spec lookup(Ash.UUID.t()) :: {:ok, answer()}
  def lookup(credential_id) when is_binary(credential_id),
    do: {:ok, %{status: :unknown, reference: nil}}

  defp reference(credential_id) do
    "stub-registry:" <>
      (:sha256
       |> :crypto.hash(credential_id)
       |> Base.encode16(case: :lower)
       |> binary_part(0, 16))
  end
end
