defmodule AshEnterprise.Audit.ClearRecordsForReplay do
  @moduledoc """
  Wipes derived state so the audit log can be replayed onto a clean slate.

  AshEvents replay reconstructs resource state by re-running every recorded event
  in order. That only produces a correct result if it starts from empty — replaying
  a create over an existing row is an error, not an idempotent no-op.

  ## Why this raises instead of truncating

  Replay is a recovery and rebuild tool, and the operation it needs is
  indistinguishable from "delete all business data". A generic implementation
  here would be a `TRUNCATE` of most of the database reachable from a mix task —
  and the failure mode is silent and total.

  So this deliberately refuses by default. Implementing it is a decision each
  deployment makes with its own list of tables and its own guard rails, not
  something a template should pre-authorize.

  ## Implementing it

  Enumerate the resources you intend to rebuild and truncate them in
  foreign-key-safe order:

      @impl true
      def clear_records!(_opts) do
        AshEnterprise.Repo.query!(\"\"\"
        TRUNCATE TABLE teams, team_memberships RESTART IDENTITY CASCADE
        \"\"\")
        :ok
      end

  Guard rails worth having before you do:

    * Refuse to run unless `Mix.env() != :prod` or an explicit override is set.
    * Never truncate `audit_events` — it is the input to the replay.
    * Take a backup first. Replay reconstructs what was *recorded*; anything
      written outside an audited action is not in the log and will not come back.
  """

  use AshEvents.ClearRecordsForReplay

  @impl true
  def clear_records!(_opts) do
    raise """
    #{inspect(__MODULE__)}.clear_records!/1 is not implemented.

    Event replay requires clearing derived state first, and doing that correctly
    means naming the tables to truncate for your deployment. A default
    implementation here would be an untargeted TRUNCATE of your business data
    reachable from a mix task, so this refuses instead.

    Implement it in lib/ash_enterprise/audit/clear_records_for_replay.ex.
    See the moduledoc for the shape and the guard rails to add.
    """
  end
end
