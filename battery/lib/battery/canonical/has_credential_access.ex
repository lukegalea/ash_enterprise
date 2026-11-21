defmodule Battery.Canonical.HasCredentialAccess do
  @moduledoc """
  A person holds the credential grant or they do not: an actor map
  carrying `credential_access?: true` may read the credential's number;
  nobody else can.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def match?(%{credential_access?: true}, _context, _opts), do: true
  def match?(_, _, _), do: false

  @impl true
  def describe(_opts), do: "the actor carries the credential grant"
end
