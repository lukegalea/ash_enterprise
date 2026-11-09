defmodule AshEnterprise.Accounts.Preparations.ActiveOnly do
  @moduledoc """
  Restricts a read to users whose lifecycle is `:active`.

  Every way a user is *found* for authentication carries it -- password and
  token sign-in, `get_by_subject` (session and bearer tokens), the lookup behind
  a password reset and the API key sign-in -- so a deactivated user is "not
  found" at each door, and the refusal reads like any other failed sign-in.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context), do: Ash.Query.filter(query, lifecycle_status == :active)
end
