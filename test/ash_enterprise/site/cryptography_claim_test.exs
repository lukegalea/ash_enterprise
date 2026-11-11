defmodule AshEnterprise.Site.CryptographyClaimTest do
  @moduledoc """
  The proof page and the control map both list where this application uses keyed
  or encrypting cryptography. Each list was once short by every HMAC the code
  computes, so this test holds them to the code: a module that starts calling
  such a primitive fails here until both pages name what it is for.

  Plain `:crypto.hash/2` is not in scope. Here it is a content fingerprint (a
  digest of a snapshot, an eval set, an uploaded file), not a secret.
  """

  use ExUnit.Case, async: true

  @pages ["site/src/pages/proof.astro", "docs/COMPLIANCE.md"]

  @keyed_or_encrypting ~r/:crypto\.(mac|crypto_one_time|crypto_init|sign|verify|private_|public_)|:public_key\.|Plug\.Crypto|Signature\.valid/

  # Each module that uses one, and the words both pages use for its job.
  @named %{
    "lib/ash_enterprise/credentialing/registry_webhook.ex" => "checking signed provider webhooks",
    "lib/ash_enterprise/erasure/crypto.ex" => "sub-keys of an erasure scope's key",
    "lib/ash_enterprise/execution/digest_key.ex" => "invocation argument digests",
    "lib/ash_enterprise/mdm/assertion_digest_key.ex" => "master-data assertion digests"
  }

  test "every module that uses keyed or encrypting cryptography is one the pages name" do
    found =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ @keyed_or_encrypting))
      |> Enum.sort()

    assert found == @named |> Map.keys() |> Enum.sort(),
           "the modules using keyed or encrypting cryptography changed; say what the new one " <>
             "is for in #{Enum.join(@pages, " and ")}, then list it here"
  end

  test "both pages name every job, and the primitives that do them" do
    for page <- @pages do
      text = page |> File.read!() |> String.replace(~r/\s+/, " ")

      for phrase <-
            Map.values(@named) ++ ["AES-256-GCM", "HMAC-SHA256", "bcrypt", "SHA-256 hash chain"] do
        assert text =~ phrase, "#{page} does not say #{inspect(phrase)}"
      end
    end
  end
end
