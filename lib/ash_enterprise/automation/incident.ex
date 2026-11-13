defmodule AshEnterprise.Automation.Incident do
  @moduledoc """
  One incident in a tenant: the alerts that share a key, from the first one that fired until
  the incident closes. A duplicate alert joins the open incident instead of opening a second,
  so the people on call get one task per incident, not one per notification.

  `AshEnterprise.Automation.Incidents` is the only writer. It runs when an `alert.firing` or
  `alert.resolved` occurrence is recorded (`AshEnterprise.Automation.Changes.TrackIncident`),
  in the same transaction, as the `oban` system actor:

  | The alert | The incident |
  |---|---|
  | fires, and no incident with its key is open | `open`: a new incident, `alert_count` 1 |
  | fires, and one is open | `join`: `alert_count` and `last_alert_at` move, and its series is added to `firing_series` |
  | fires, and the open one's triage has finished | `close` that one (`triage_concluded`), then `open` a new one carrying the series still firing |
  | resolves, and another series of the rule is still firing | `resolve_series`: its series leaves `firing_series`, and the incident stays open |
  | resolves, and no other series is firing | `close` the open one (`alert_resolved`) |

  The key is the provider and the alerting rule (`"signoz:<rule id>"`, or the alert's name
  when a provider gives no rule id), so the same rule firing again is the same incident, and
  another rule is another incident.

  ## One rule, several series

  A rule fires once per label set: SigNoz sends one alert per series, each with its own
  fingerprint and the rule's id. They are one incident, and it stays open while any of them
  fires. `firing_series` holds the series still firing; a resolution of one series closes
  the incident only when it was the last. Without this, the first series to resolve would
  close the incident while the others still fire, and their renotifications, which are
  replays of alerts already recorded, would never open it again. An alert with no series
  (a provider that gives none) closes the incident on resolving, as before.

  Opening is an audited create, so a recipe can match it: the `incident_triage` pack
  (`priv/packs/incident_triage/`) starts a triage process whose task goes to the tenant's
  **On-call** role. Joining and closing are audited updates no pack matches.

  ## What it holds

  The alert's few short labels (title, severity, category, provider) and counts and times.
  Nothing from an alert's body: an occurrence keeps no annotation, description or value, and
  neither does this.

  ## Written only by the platform

  `open`, `join` and `close` are machinery-only: no grant lets a tenant member write an
  incident. Reading follows the grant union; the starter On-call role reads incidents
  (`AshEnterprise.Platform.Seeder.ensure_on_call_role/2`). There is no destroy and no
  archival: an incident that happened stays in the record. Not exposed over any API.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Automation,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:open, :join, :resolve_series, :close]

  postgres do
    table "automation_incidents"
    repo AshEnterprise.Repo

    identity_wheres_to_sql one_open_per_key: "status = 'open'"
  end

  actions do
    defaults [:read]

    create :open do
      description "Open an incident for an alert whose key has none open. Machinery only."
      primary? true

      accept [
        :key,
        :title,
        :severity,
        :category,
        :provider,
        :opened_by_occurrence_id,
        :firing_series
      ]

      argument :at, :utc_datetime_usec, allow_nil?: false
      change set_attribute(:first_alert_at, arg(:at))
      change set_attribute(:last_alert_at, arg(:at))
    end

    update :join do
      description "Count another alert into the open incident with its key. Machinery only."
      # Not atomic: see `AshEnterprise.Automation.Changes.CountAlert`.
      require_atomic? false
      argument :at, :utc_datetime_usec, allow_nil?: false
      argument :series, :string, constraints: [max_length: 200]
      validate attribute_equals(:status, :open)
      change AshEnterprise.Automation.Changes.CountAlert
      change set_attribute(:last_alert_at, arg(:at))
      change {AshEnterprise.Automation.Changes.FiringSeries, op: :add}
    end

    update :resolve_series do
      description """
      One series of the open incident's rule resolved while another still fires: it leaves
      `firing_series`, and the incident stays open. Machinery only.
      """

      require_atomic? false
      argument :series, :string, allow_nil?: false, constraints: [max_length: 200]
      validate attribute_equals(:status, :open)
      change {AshEnterprise.Automation.Changes.FiringSeries, op: :remove}
    end

    update :close do
      description "Close the open incident: its alert resolved, or its triage finished. Machinery only."

      argument :reason, :atom do
        allow_nil? false
        constraints one_of: [:alert_resolved, :triage_concluded]
      end

      require_atomic? false
      validate attribute_equals(:status, :open)
      change set_attribute(:status, :closed)
      change set_attribute(:closed_reason, arg(:reason))
      change set_attribute(:closed_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200

      description "The provider and the alerting rule: alerts with the same key are one incident."
    end

    attribute :title, :string do
      public? true
      constraints max_length: 120
      description "The alert's name, as its rule labels it."
    end

    attribute :severity, :string do
      public? true
      constraints max_length: 120
    end

    attribute :category, :string do
      public? true
      constraints max_length: 120
    end

    attribute :provider, :string do
      public? true
      constraints max_length: 60
      description "Which tool raised the alert, e.g. `signoz` or `glitchtip`."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :open
      constraints one_of: [:open, :closed]
    end

    attribute :closed_reason, :atom do
      public? true
      constraints one_of: [:alert_resolved, :triage_concluded]
    end

    attribute :alert_count, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    attribute :first_alert_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_alert_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :closed_at, :utc_datetime_usec do
      public? true
    end

    attribute :firing_series, {:array, :string} do
      allow_nil? false
      public? true
      default []

      description "The series of the rule still firing, as the provider identifies them " <>
                    "(SigNoz's fingerprint). The incident closes on a resolution only when " <>
                    "none is left."
    end

    attribute :opened_by_occurrence_id, :uuid do
      public? true
      description "The `alert.firing` occurrence that opened it."
    end
  end

  identities do
    # At most one open incident per key in a tenant: the writer takes a lock per key, and
    # this index is what holds if anything ever writes around it.
    identity :one_open_per_key, [:key], where: expr(status == :open)
  end
end
