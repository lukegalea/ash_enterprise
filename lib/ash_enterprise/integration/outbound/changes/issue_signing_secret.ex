defmodule AshEnterprise.Integration.Outbound.Changes.IssueSigningSecret do
  @moduledoc """
  Issues an endpoint's signing secret and seals it under the endpoint's own erasure scope.

  The secret is a Standard Webhooks key, `whsec_` followed by 32 random bytes in base64. It
  is sealed under the scope `(:connection, "outbound_endpoint:<id>")`, opened the first time
  (on `register`) and reused on `rotate_secret`, and stored only sealed, in the sensitive
  `sealed_secret` attribute, so the audit event records it as `nil`. Shredding that scope
  makes the secret unreadable, and the endpoint can sign nothing again.

  The plaintext is handed back once, as the `signing_secret` metadata of the record the
  action returns, and is never stored or logged in the clear.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.{Keyring, Scope}
  alias AshEnterprise.Platform.SystemActor

  @label "outbound webhook endpoint"

  @impl true
  def change(changeset, _opts, _context) do
    # In a before_action, so a changeset built only to ask `can?` opens no scope and seals
    # nothing.
    Ash.Changeset.before_action(changeset, &issue/1)
  end

  defp issue(changeset) do
    secret = "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
    changeset = ensure_id(changeset)

    with {:ok, scope_id} <- scope(changeset),
         {:ok, sealed} <- Keyring.seal(scope_id, secret) do
      changeset
      |> Ash.Changeset.force_change_attribute(:erasure_scope_id, scope_id)
      |> Ash.Changeset.force_change_attribute(:sealed_secret, Base.encode64(sealed))
      |> Ash.Changeset.after_action(fn _changeset, record ->
        {:ok, Ash.Resource.put_metadata(record, :signing_secret, secret)}
      end)
    else
      {:error, :shredded} -> shredded(changeset)
      {:error, :unknown_scope} -> shredded(changeset)
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  # The scope's ref names the endpoint, so a create fixes its id before the default would.
  defp ensure_id(%{action_type: :create} = changeset) do
    case Ash.Changeset.get_attribute(changeset, :id) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :id, Ash.UUID.generate())
      _id -> changeset
    end
  end

  defp ensure_id(changeset), do: changeset

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "a signing secret is sealed under the endpoint's erasure scope key"}

  defp scope(%{action_type: :create} = changeset) do
    ref = "outbound_endpoint:#{Ash.Changeset.get_attribute(changeset, :id)}"

    case Erasure.ensure_scope(:connection, ref, %{label: @label}, actor: SystemActor.system()) do
      {:ok, %Scope{status: :active, id: id}} -> {:ok, id}
      {:ok, %Scope{}} -> {:error, :shredded}
      {:error, error} -> {:error, error}
    end
  end

  defp scope(changeset) do
    case changeset.data.erasure_scope_id do
      nil -> {:error, :unknown_scope}
      scope_id -> {:ok, scope_id}
    end
  end

  defp shredded(changeset) do
    Ash.Changeset.add_error(changeset,
      field: :erasure_scope_id,
      message: "the endpoint's erasure scope is shredded; register a new endpoint"
    )
  end
end
