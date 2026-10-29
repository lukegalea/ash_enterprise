defmodule AshEnterprise.Execution.DigestKey do
  @moduledoc """
  The key an invocation's `args_digest` is an HMAC under (`AshAgent.DigestKey`, decision
  D10).

  Derived from the key of the erasure scope the invocation's content is sealed under:
  HMAC-SHA256 of a fixed label under the scope's data key, so the data key itself is
  never used for two purposes. Shredding the scope therefore also makes the digest
  impossible to recompute, and a guess at the arguments cannot be checked against it.
  A shredded scope has no key, and the digest cannot be taken or compared.
  """

  @behaviour AshAgent.DigestKey

  alias AshEnterprise.Erasure.Keyring

  @label "ash_agent/invocation/args_digest/v1"

  @impl true
  def digest_key(%{erasure_scope_id: scope_id}) when is_binary(scope_id) do
    with {:ok, data_key} <- Keyring.live_key(scope_id) do
      {:ok, :crypto.mac(:hmac, :sha256, data_key, @label)}
    end
  end

  def digest_key(_invocation), do: {:error, :no_erasure_scope}
end
