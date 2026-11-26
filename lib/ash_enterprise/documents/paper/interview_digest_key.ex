defmodule AshEnterprise.Documents.Paper.InterviewDigestKey do
  @moduledoc """
  The key `AshEnterprise.Documents.Paper.Interview`'s subject state digest is an
  HMAC under. The digest covers an organization's scope (a kind's period, say) as the document saw
  it (the typed facts: categories and amounts) and is stored beside a person's
  answer in the facts table, which is not sealed; a few amounts hashed without a
  key can be recovered by trying candidates.

  Derived from the endpoint's `secret_key_base` under its own label, so the key
  is never the secret itself and is useless for anything else the secret signs.
  It is read at each use and stays out of compiled code.

  Rotating `secret_key_base` changes every digest: each recorded answer then
  reads as stale and is asked once more, and nothing is read as answered that
  was not.
  """

  @label "ash_enterprise/paper/interview/state_digest/v1"

  @spec key() :: binary()
  def key do
    secret =
      :ash_enterprise
      |> Application.fetch_env!(AshEnterpriseWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    :crypto.mac(:hmac, :sha256, secret, @label)
  end
end
