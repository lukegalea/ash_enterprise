defmodule AshEnterprise.Erasure.Keyring do
  @moduledoc """
  Where scope keys are issued, fetched and resolved — the only module that reads
  `AshEnterprise.Erasure.Key` rows.

  It reads them with `authorize?: false`, and that is the design rather than a
  shortcut: `Key` grants no actor anything (see its policies), so key material
  is reachable through exactly one code path, this one, and never through the
  admin UI, an API or an agent tool.

  ## No cache, on purpose

  Every seal and every open fetches the scope's key row and unwraps it. A cache
  of unwrapped keys would make a shred take effect "eventually" on every node
  that had warmed it — and "eventually" is not an erasure guarantee. The cost is
  one primary-key lookup per sealed value read; batching it is a performance
  change for when it is measured to matter.

  ## Failure is loud everywhere except one place

  Exactly one outcome reads as `AshEnterprise.Erasure.Shredded`: the scope
  exists and is `:shredded`. Everything else that stops a value opening — a live
  scope whose key row is missing, a key that does not unwrap under the configured
  master key, a ciphertext that fails authentication, a scope id nobody issued —
  raises. Those are a lost key, a wrong master key and tampering, and reporting
  any of them as "shredded" would make data loss look like a successful erasure.
  """

  alias AshEnterprise.Erasure.{Crypto, Key, Scope, Shredded}

  @doc """
  Issues the one key a scope will ever have. Called inside the transaction that
  creates the scope, so a scope without a key cannot commit. A second issue for
  the same scope, or a DEK whose fingerprint already exists, fails on the `Key`
  identities.
  """
  @spec issue!(Scope.t()) :: Key.t()
  def issue!(%Scope{id: scope_id}) do
    kek = Crypto.master_key!()
    dek = Crypto.generate_key()

    Key.issue!(
      %{
        scope_id: scope_id,
        wrapped_key: Crypto.wrap(dek, scope_id, kek),
        fingerprint: Crypto.fingerprint(dek),
        master_key_id: Crypto.master_key_id(kek)
      },
      authorize?: false
    )
  end

  @doc """
  The scope's DEK while it is live.

  `{:error, :shredded}` for a shredded scope and `{:error, :unknown_scope}` for an
  id that was never issued. A live scope with no key raises (see the moduledoc).
  """
  @spec live_key(Ash.UUID.t()) :: {:ok, binary()} | {:error, :shredded | :unknown_scope}
  def live_key(scope_id) do
    case Key.for_scope(scope_id, authorize?: false) do
      {:ok, %Key{} = key} -> {:ok, unwrap!(key)}
      {:ok, nil} -> keyless(scope_id)
    end
  end

  @doc """
  Seals a plaintext binary under a live scope's key. Refuses a shredded or
  unknown scope: nothing new may land under a scope whose key is gone, and a
  scope cannot be resurrected by writing to it.
  """
  @spec seal(Ash.UUID.t(), binary()) :: {:ok, binary()} | {:error, :shredded | :unknown_scope}
  def seal(scope_id, plaintext) do
    with {:ok, dek} <- live_key(scope_id) do
      {:ok, Crypto.seal(plaintext, scope_id, dek)}
    end
  end

  @doc """
  Opens a sealed binary: the plaintext while its scope is live, the
  `Shredded` marker once it is not. Raises on everything else.
  """
  @spec open!(binary()) :: {:ok, binary()} | {:shredded, Shredded.t()}
  def open!(sealed) do
    scope_id =
      case Crypto.scope_of(sealed) do
        {:ok, scope_id} -> scope_id
        :error -> raise ArgumentError, "not an erasure-sealed value (no AEE1 header)"
      end

    case live_key(scope_id) do
      {:ok, dek} ->
        case Crypto.open(sealed, dek) do
          {:ok, plaintext} ->
            {:ok, plaintext}

          :error ->
            raise ArgumentError,
                  "sealed value for erasure scope #{scope_id} failed authentication: " <>
                    "the ciphertext was altered or does not belong to that scope"
        end

      {:error, :shredded} ->
        {:shredded, %Shredded{erasure_scope_id: scope_id}}

      {:error, :unknown_scope} ->
        raise ArgumentError,
              "sealed value names erasure scope #{scope_id}, which was never issued"
    end
  end

  defp keyless(scope_id) do
    case AshEnterprise.Erasure.get_scope(scope_id, authorize?: false, not_found_error?: false) do
      {:ok, %Scope{status: :shredded}} ->
        {:error, :shredded}

      {:ok, nil} ->
        {:error, :unknown_scope}

      {:ok, %Scope{status: :active}} ->
        raise "erasure scope #{scope_id} is active but has no key: its content is " <>
                "unrecoverable. This is a lost key, not a shred -- investigate before anything else."
    end
  end

  defp unwrap!(%Key{} = key) do
    kek = Crypto.master_key!()

    case Crypto.unwrap(key.wrapped_key, key.scope_id, kek) do
      {:ok, dek} ->
        dek

      :error ->
        configured = Crypto.master_key_id(kek)

        detail =
          if configured == key.master_key_id do
            "the wrapped key was altered or moved from another scope"
          else
            "it was wrapped under master key #{key.master_key_id} and the configured " <>
              "master key is #{configured}"
          end

        raise "erasure key for scope #{key.scope_id} does not unwrap: #{detail}"
    end
  end
end
