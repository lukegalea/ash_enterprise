defmodule AshEnterprise.Canonical do
  @moduledoc """
  The canonical model (epic E4, dogfood §11): the interpreted rows the external
  systems only observe. Gmail, Google Calendar and Slack stay systems of
  engagement; this domain holds what they *mean* — people, conversations,
  messages, events, commitments, projects — normalized once, in one place.

  Rows arrive in two ways:

    * **Projected** from `AshEnterprise.Ingestion.SourceObject` raw landings by
      `AshEnterprise.Canonical.Projection` (ADR 0037's host-declared pattern).
      Deterministic replay is the correctness proof: delete the canonical rows,
      replay, and the result is byte-identical.
    * **Created directly** by the operator for native rows (quick-capture
      tasks, manual projects) — `external_system`/`external_id` stay nil for
      these, which is why the external identity is nullable on every resource.

  Linkage is deliberately v1-crude: external id + email only. There is no fuzzy
  entity resolution — that is the roadmap's P4 item, and a wrong automatic merge
  is far more expensive than a duplicate person row.

  ## Zones (ADR 0042)

  `Person`, `Conversation` and `Message` are personal data. The Gmail/Slack
  verticals must not enable their projectors until zone admission is checked on
  the SourceObject land path; see the TODO on
  `AshEnterprise.Canonical.Projection`. The calendar fixture is deterministic
  synthetic data and needs no admission.
  """

  use Ash.Domain,
    extensions: [AshPhoenix]

  resources do
    resource AshEnterprise.Canonical.Person
    resource AshEnterprise.Canonical.Account
    resource AshEnterprise.Canonical.Conversation
    resource AshEnterprise.Canonical.Message
    resource AshEnterprise.Canonical.CalendarEvent
    resource AshEnterprise.Canonical.Task
    resource AshEnterprise.Canonical.Project
  end
end
