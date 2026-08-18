defmodule AshEnterpriseWeb.AshJsonApiRouter do
  @moduledoc """
  The JSON:API router, and the list of domains it serves.

  Which domains appear here is a security decision, not a routing one; the
  comment below records why `Security` and `Audit` are absent.
  """
  # Domains whose `json_api do routes do ... end` declarations become HTTP routes.
  # An empty list here produces a router that serves nothing and an OpenAPI
  # document with no paths -- which looks like a working API until you request
  # one, so it is worth checking this list when a route 404s unexpectedly.
  #
  # Security and Audit are deliberately absent: a filterable public API over the
  # authorization tables is a map of the security model, and over the audit log
  # it discloses the existence of records the caller may not be able to read.
  use AshJsonApi.Router,
    domains: [AshEnterprise.Accounts],
    open_api: "/open_api"
end
