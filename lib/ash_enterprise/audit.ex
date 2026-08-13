defmodule AshEnterprise.Audit do
  @moduledoc """
  The audit domain: one central, append-only event log covering every platform
  resource.

  See ADR 0002 for why this is a single log rather than per-resource version
  tables, and `docs/manifesto/04-batteries-are-inherited.md` for how resources
  are wired to it by inheritance rather than by remembering.

  Deliberately **not** exposed over JSON:API or GraphQL. Audit data is read
  through the admin UI and through purpose-built queries, because a generic
  filterable API over the audit log is an information-disclosure surface: it
  reveals the existence and shape of records the caller may not be able to read
  directly.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource AshEnterprise.Audit.EventLog
  end
end
