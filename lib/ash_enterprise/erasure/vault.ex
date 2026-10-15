defmodule AshEnterprise.Erasure.Vault do
  @moduledoc """
  The `ash_cloak` vault for content sealed under an erasure scope.

  `ash_cloak` supplies the structure: on a cloaked resource the attribute
  becomes an `encrypted_<name>` binary column, the action input becomes a
  `sensitive?` argument (so AshEvents records it as `nil` in `data`), and the
  attribute's name becomes a calculation that decrypts through this vault.

  ## Why the write side is not `encrypt!/1`

  An `ash_cloak` vault's contract is `encrypt!(plaintext)` — no record, no
  changeset — so a per-scope key cannot reach it without smuggling state through
  the process. Rather than do that, writes are sealed by
  `AshEnterprise.Erasure.Changes.SealUnderScope`, which reads the scope id off
  the changeset and runs *before* `ash_cloak`'s own encrypt hook (which then has
  no argument left to encrypt). `encrypt!/1` here therefore raises: there is no
  global key, and a write that reaches it bypassed the scope.

  ## The read side

  Sealed values are self-describing (`AshEnterprise.Erasure.Crypto`), so
  `decrypt!/1` needs no context: the header names the scope, the keyring
  fetches that scope's key. A shredded scope decrypts to a serialized
  `AshEnterprise.Erasure.Shredded` struct, which `ash_cloak`'s decrypt
  calculation hands back as the attribute's value.
  """

  alias AshEnterprise.Erasure.Keyring

  @doc "The `ash_cloak` vault resolver: `vault {AshEnterprise.Erasure.Vault, :resolve, []}`."
  def resolve(_resource, _context), do: __MODULE__

  @doc "Always raises: there is no global key. See the moduledoc."
  def encrypt!(_plaintext) do
    raise ArgumentError,
          "AshEnterprise.Erasure.Vault has no global key. Content is sealed under its erasure " <>
            "scope by AshEnterprise.Erasure.Changes.SealUnderScope; a write reaching encrypt!/1 " <>
            "skipped that change (or set the encrypted attribute without an erasure scope)."
  end

  @doc "Decrypts a sealed value, or returns the serialized shredded marker."
  def decrypt!(sealed) do
    case Keyring.open!(sealed) do
      {:ok, plaintext} -> plaintext
      {:shredded, marker} -> :erlang.term_to_binary(marker)
    end
  end
end
