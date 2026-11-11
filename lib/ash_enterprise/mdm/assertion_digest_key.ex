defmodule AshEnterprise.Mdm.AssertionDigestKey do
  @moduledoc """
  The key `AshEnterprise.Mdm.AttributeAssertion`'s `content_digest` is an HMAC
  under: a name or an address hashed without one can be recovered by trying
  candidates.

  Derived from the endpoint's `secret_key_base` under its own label, so the
  digest key is never the secret itself and is useless for anything else the
  secret signs. It is read at each write and stays out of compiled code.

  Rotating `secret_key_base` changes every digest. A statement already stored
  then no longer dedupes against its own re-import, which costs one extra row
  and changes no folded value: only a source's newest statement competes.
  """

  @label "ash_enterprise/mdm/attribute_assertion/content_digest/v1"

  @spec key() :: binary()
  def key do
    secret =
      :ash_enterprise
      |> Application.fetch_env!(AshEnterpriseWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    :crypto.mac(:hmac, :sha256, secret, @label)
  end
end
