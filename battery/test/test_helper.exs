# The battery's test boot, for `mix test` runs. `mix platform_battery`
# performs the same boot inside the task.
#
# Postgres connection details come from the environment (PGHOST/PGPORT/
# PGUSER/PGPASSWORD with local defaults — see config/test.exs).
#
# Storage up runs BEFORE the repos start (the sandbox pool opens its
# connections eagerly at start_link). Migrations run outside the sandbox
# (:auto); the pool switches to manual ownership afterwards.
[
  Battery.Domain,
  Battery.Repo,
  Battery.Events.EventLog,
  Battery.SystemOne.CaseFile,
  Battery.SystemOne.Judgment,
  Battery.SystemOne.Fact,
  Battery.SystemOne.Banding,
  Battery.Decisions.Definition,
  Battery.Decisions.Evaluation,
  Battery.Bpmn.Definition,
  Battery.Bpmn.Instance,
  Battery.Bpmn.Token,
  Battery.Bpmn.ProcessEvent,
  Battery.Bpmn.Subject,
  Battery.BusinessEvents.SourceRecord,
  Battery.BusinessEvents.Ledger,
  Battery.BusinessEvents.MappingVersion,
  Battery.BusinessEvents.VendorState,
  Battery.Compliance.EventLog,
  Battery.Mdm.Vendor,
  Battery.Mdm.Mapping,
  Battery.Mdm.MatchRuleSet,
  Battery.Mdm.MatchCandidate,
  Battery.Execution.Member,
  Battery.Execution.Referral,
  Battery.Execution.Invocation,
  AshEvidence.Domain,
  AshCompliance.Domain
]
|> Enum.each(&Code.ensure_loaded!/1)

for repo <- [Battery.Repo, AshEvidence.Repo] do
  case repo.__adapter__().storage_up(repo.config()) do
    :ok -> :ok
    {:error, :already_up} -> :ok
  end

  {:ok, _} = repo.start_link()

  Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)

  migrations = Path.join(:code.priv_dir(:ash_enterprise_battery), "repo/migrations")
  Ecto.Migrator.run(repo, migrations, :up, all: true)

  Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
end

ExUnit.start()
