defmodule AshEnterprise.Audit.ClearRecordsForReplay do
  @moduledoc """
  Wipes derived state so the audit log can be replayed onto a clean slate.

  AshEvents replay reconstructs resource state by re-running every recorded event
  in order. That only produces a correct result if it starts from empty — replaying
  a create over an existing row is an error, not an idempotent no-op.

  ## A configured list, and a guard

      config :ash_enterprise, AshEnterprise.Audit.ClearRecordsForReplay,
        allow?: true,
        resources: [AshEnterprise.Accounts.BusinessUnit]

  Replay is a recovery and rebuild tool, and the operation it needs is
  indistinguishable from "delete all business data". So clearing is refused unless
  `allow?` is true, which only `config/dev.exs` and `config/test.exs` set: production
  refuses, as it always has. When allowed, it deletes the rows of the resources named
  in `resources` and nothing else, children last in the list, so name parents first.

  It also refuses, before deleting anything, when a replay could not rebuild what it
  clears:

    * **an audited resource that is not on the list has events in the log.** The replay
      re-runs every event in the log, not only the listed ones, so it would re-create
      rows that were never cleared and fail on the first duplicate. The list must cover
      the log.
    * **the archive holds events** (`AshEnterprise.Audit.ArchivedEvent`). Replay reads
      the hot log only, so after a retention run it would rebuild from a log missing its
      oldest events and produce the wrong state without an error.
    * **the list names the audit log or an unaudited resource.** `audit_events` is the
      replay's input, and a resource with no events has nothing to rebuild from.

  Replay reconstructs what was *recorded*: anything written outside an audited action
  is not in the log and will not come back. Take a backup first
  (`scripts/backup-restore-drill` shows the restore).

  ## Why this module writes SQL

  Clearing must not go through the resources' destroy actions: those archive rather
  than delete, and every one of them would append to the audit log the replay is about
  to read. It is the replay machinery's own step, so a plain `DELETE` per configured
  table, behind the checks above.
  """

  use AshEvents.ClearRecordsForReplay

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Repo

  @impl true
  def clear_records!(_opts) do
    config = Application.get_env(:ash_enterprise, __MODULE__, [])
    resources = Keyword.get(config, :resources, [])

    unless Keyword.get(config, :allow?, false) == true do
      raise """
      #{inspect(__MODULE__)} refuses: clearing records for replay is not allowed here.

      Event replay deletes the rows of the resources it rebuilds. It is allowed only where
      `config :ash_enterprise, #{inspect(__MODULE__)}, allow?: true` is set, which dev and
      test do and production does not.
      """
    end

    tables = Enum.map(resources, &table!/1)

    check_log_covered!(resources)
    check_archive_empty!()

    # Children first: the list names parents first.
    for table <- Enum.reverse(tables), do: Repo.query!(~s(DELETE FROM "#{table}"))

    :ok
  end

  defp table!(EventLog),
    do: raise(ArgumentError, "the audit log is the replay's input; never clear it")

  defp table!(resource) do
    cond do
      not Ash.Resource.Info.resource?(resource) ->
        raise ArgumentError, "#{inspect(resource)} is not an Ash resource"

      AshEvents.Events.Info.events_event_log(resource) != {:ok, EventLog} ->
        raise ArgumentError,
              "#{inspect(resource)} is not audited, so the log cannot rebuild it; do not clear it"

      true ->
        AshPostgres.DataLayer.Info.table(resource)
    end
  end

  defp check_log_covered!(resources) do
    listed = MapSet.new(resources, &Atom.to_string/1)

    %{rows: rows} = Repo.query!("SELECT DISTINCT resource FROM audit_events ORDER BY 1")

    case Enum.reject(for([name] <- rows, do: name), &MapSet.member?(listed, &1)) do
      [] ->
        :ok

      missing ->
        raise """
        #{inspect(__MODULE__)} refuses: the log holds events for resources the clear list
        does not name, and a replay re-runs every event in the log:

          #{Enum.join(missing, "\n  ")}

        Name them (parents first) or replay a log that holds only the listed resources.
        """
    end
  end

  defp check_archive_empty! do
    case Repo.query!("SELECT count(*) FROM audit_event_archive").rows do
      [[0]] ->
        :ok

      [[count]] ->
        raise """
        #{inspect(__MODULE__)} refuses: #{count} event(s) have moved to the archive, and replay
        reads only the hot log. A rebuild from it would be missing its oldest events.
        """
    end
  end
end
