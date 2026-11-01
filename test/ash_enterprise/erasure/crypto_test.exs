defmodule AshEnterprise.Erasure.CryptoTest do
  @moduledoc "Subkeys and keyed digests (`AshEnterprise.Erasure.Crypto`): pure, no database."

  use ExUnit.Case, async: true

  alias AshEnterprise.Erasure.Crypto

  test "a subkey is fixed for a key and label, and differs by either" do
    key = Crypto.generate_key()
    other = Crypto.generate_key()

    assert byte_size(Crypto.derive_key(key, "digest")) == 32
    assert Crypto.derive_key(key, "digest") == Crypto.derive_key(key, "digest")
    refute Crypto.derive_key(key, "digest") == Crypto.derive_key(key, "id")
    refute Crypto.derive_key(key, "digest") == Crypto.derive_key(other, "digest")
    refute Crypto.derive_key(key, "digest") == key
  end

  test "a keyed digest is lowercase hex, stable, and unrelated across subkeys" do
    a = Crypto.derive_key(Crypto.generate_key(), "digest")
    b = Crypto.derive_key(Crypto.generate_key(), "digest")

    digest = Crypto.keyed_digest(a, "same content")
    assert digest =~ ~r/\A[0-9a-f]{64}\z/
    assert digest == Crypto.keyed_digest(a, ["same ", "content"])
    refute digest == Crypto.keyed_digest(b, "same content")
    refute digest == :sha256 |> :crypto.hash("same content") |> Base.encode16(case: :lower)
  end

  test "a key of the wrong size is refused" do
    assert_raise FunctionClauseError, fn -> Crypto.derive_key(<<1, 2, 3>>, "digest") end
  end
end
