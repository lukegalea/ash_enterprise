defmodule AshEnterprise.Erasure.Crypto do
  @moduledoc """
  The pure cryptography behind crypto-shredding (ADR 0024). No database, no
  configuration lookups beyond the master key — `AshEnterprise.Erasure.Keyring`
  is the part that knows where keys live.

  ## Two layers, both AES-256-GCM

    * **Wrapping.** Each erasure scope has its own 256-bit data-encryption key
      (DEK). At rest the DEK is stored only *wrapped* — encrypted under the
      master key-encryption key (KEK) from configuration — with the scope id as
      additional authenticated data. The binding is the point: a wrapped key
      copied onto another scope's row does not unwrap, so a bug that reuses a key
      across scopes fails loudly instead of silently widening a shred.
    * **Sealing.** Content is encrypted under its scope's DEK. The sealed binary
      is self-describing:

          "AEE1" <> scope_id (16 raw bytes) <> iv (12) <> tag (16) <> ciphertext

      and the header (magic + scope id) is the additional authenticated data, so
      rewriting a ciphertext's scope id to point at a different key fails
      authentication rather than decrypting under the wrong key.

  Every IV is fresh from `:crypto.strong_rand_bytes/1`; nothing here is
  deterministic, which is why a re-landed or re-projected row carries different
  ciphertext bytes for the same plaintext.

  ## The master key

  Read from `config :ash_enterprise, AshEnterprise.Erasure, master_key: <base64>`
  — 32 bytes once decoded. `config/runtime.exs` requires it from
  `ERASURE_MASTER_KEY` in production; in dev it takes `ERASURE_MASTER_KEY` when
  set and otherwise generates one into the devenv state directory
  (`.devenv/state/erasure/master.key`) on first use; `config/test.exs` generates
  one per run. **Losing the master key is an irreversible shred of every scope at once.**
  It is never committed, and it is a production secret of the same class as the
  database password.
  """

  @magic "AEE1"
  @key_aad "ash_enterprise/erasure/key/v1:"
  @fingerprint_domain "ash_enterprise/erasure/fingerprint/v1:"
  @iv_bytes 12
  @tag_bytes 16
  @key_bytes 32

  @doc "A fresh 256-bit data-encryption key."
  @spec generate_key() :: binary()
  def generate_key, do: :crypto.strong_rand_bytes(@key_bytes)

  @doc """
  A domain-separated SHA-256 of a DEK, hex-encoded. Stored beside the wrapped key
  under a unique identity so the database itself refuses two scopes holding the
  same key bytes. It reveals nothing usable about a 256-bit random key.
  """
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(<<_::binary-size(@key_bytes)>> = key) do
    :sha256 |> :crypto.hash([@fingerprint_domain, key]) |> Base.encode16(case: :lower)
  end

  @doc "Wraps a DEK under the KEK, bound to `scope_id`."
  @spec wrap(binary(), Ash.UUID.t(), binary()) :: binary()
  def wrap(<<_::binary-size(@key_bytes)>> = key, scope_id, kek) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    aad = @key_aad <> Ecto.UUID.dump!(scope_id)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, key, aad, true)
    iv <> tag <> ciphertext
  end

  @doc "Unwraps a DEK. `:error` means the KEK is wrong or the row was moved or altered."
  @spec unwrap(binary(), Ash.UUID.t(), binary()) :: {:ok, binary()} | :error
  def unwrap(
        <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>,
        scope_id,
        kek
      ) do
    aad = @key_aad <> Ecto.UUID.dump!(scope_id)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, ciphertext, aad, tag, false) do
      key when is_binary(key) and byte_size(key) == @key_bytes -> {:ok, key}
      _ -> :error
    end
  end

  def unwrap(_wrapped, _scope_id, _kek), do: :error

  @doc "Seals `plaintext` under a scope's DEK. See the moduledoc for the format."
  @spec seal(binary(), Ash.UUID.t(), binary()) :: binary()
  def seal(plaintext, scope_id, key) when is_binary(plaintext) do
    header = @magic <> Ecto.UUID.dump!(scope_id)
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, header, true)

    header <> iv <> tag <> ciphertext
  end

  @doc "Reads the scope id out of a sealed binary's header without decrypting it."
  @spec scope_of(binary()) :: {:ok, Ash.UUID.t()} | :error
  def scope_of(<<@magic, scope::binary-size(16), _rest::binary>>), do: Ecto.UUID.load(scope)
  def scope_of(_sealed), do: :error

  @doc "Opens a sealed binary with its scope's DEK. `:error` means tampered, or the wrong key."
  @spec open(binary(), binary()) :: {:ok, binary()} | :error
  def open(
        <<@magic, scope::binary-size(16), iv::binary-size(@iv_bytes),
          tag::binary-size(@tag_bytes), ciphertext::binary>>,
        key
      ) do
    header = @magic <> scope

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, header, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> :error
    end
  end

  def open(_sealed, _key), do: :error

  @doc """
  The configured master KEK, decoded. Raises when it is missing or malformed:
  there is no fallback key, because a fallback is how every scope ends up
  readable by whoever knows the default.
  """
  @spec master_key!() :: binary()
  def master_key! do
    encoded =
      :ash_enterprise
      |> Application.get_env(AshEnterprise.Erasure, [])
      |> Keyword.get(:master_key)

    case encoded && Base.decode64(encoded) do
      {:ok, <<_::binary-size(@key_bytes)>> = key} ->
        key

      _ ->
        raise ArgumentError,
              "no valid erasure master key: set `config :ash_enterprise, AshEnterprise.Erasure, " <>
                "master_key: <base64 of 32 random bytes>` (ERASURE_MASTER_KEY in production). " <>
                "See AshEnterprise.Erasure.Crypto."
    end
  end

  @doc """
  A short, non-secret identifier for a KEK, stored beside each wrapped key. It
  turns "the master key changed" into a named error instead of an
  authentication failure that would otherwise look exactly like tampering.
  """
  @spec master_key_id(binary()) :: String.t()
  def master_key_id(kek) do
    :sha256
    |> :crypto.hash(["ash_enterprise/erasure/kek-id/v1:", kek])
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end
end
