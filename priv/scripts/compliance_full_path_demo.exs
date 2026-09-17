# One-off full-path verification against the dev database:
# legacy write -> ledger row -> drain -> canonical action -> compliance events
# -> projector -> finding. Run: devenv shell mix run priv/scripts/compliance_full_path_demo.exs
#
require Logger
require Ash.Query

alias AshEnterprise.Compliance.EventLog
alias AshEnterprise.Ledger.UserDrainWorker
alias AshEnterprise.Repo

org = AshEnterprise.Legacy.Estate.organization_id()

# 0. Starting state
{:ok, %{rows: [[ledger_before]]}} =
  Repo.query("SELECT count(*) FROM legacy_change_events", [])

{:ok, %{rows: [[events_before]]}} = Repo.query("SELECT count(*) FROM compliance_events", [])

IO.puts("start: ledger=#{ledger_before} compliance_events=#{events_before}")

# 1. The legacy application writes. Raw SQL on purpose: nothing in this
#    application wrote this row.
leg_id = :rand.uniform(100_000) + 500_000
subject_id_str = Integer.to_string(leg_id)

Repo.query!(
  "INSERT INTO legacy.users (login, email, first_name, last_name, state) VALUES ($1, $2, $3, $4, $5)",
  ["kycdemo#{leg_id}", "kycdemo#{leg_id}@example.org", "Kim", "Subject", "active"]
)

{:ok, %{rows: [[ledger_row]]}} =
  Repo.query("SELECT id FROM legacy_change_events ORDER BY id DESC LIMIT 1", [])

IO.puts("legacy.users INSERT committed; ledger row #{ledger_row} written by the trigger")

# 2. Drain the ledger (the worker's job; the pg_notify wake only shortens the wait)
{:ok, drained} = UserDrainWorker.drain()
IO.puts("drain ingested #{drained} ledger event(s)")

# 3. Canonical + compliance side effects
{:ok, %{rows: [[events_after]]}} = Repo.query("SELECT count(*) FROM compliance_events", [])

projected =
  AshEnterprise.Accounts.ProjectedUser
  |> Ash.Query.filter(login == ^"kycdemo#{leg_id}")
  |> Ash.read_one!(authorize?: false, tenant: org)

subject_id_str = projected && Integer.to_string(projected.legacy_id)

IO.puts(
  "projected row: #{inspect(projected && {projected.login, projected.legacy_id})}; compliance events: #{events_before} -> #{events_after}"
)

# 4. The projector folds the events into findings. The server drains
#    asynchronously; flush it.
AshEvents.Projections.Server.flush(AshEnterprise.Compliance.Projector.__projector_name__())

findings =
  AshCompliance.Resources.Finding
  |> Ash.Query.filter(
    organization_id == ^org and subject_type == "user" and subject_id == ^subject_id_str
  )
  |> Ash.read!(authorize?: false)

IO.puts("findings: #{length(findings)}")

Enum.each(Enum.sort_by(findings, & &1.control_id), fn f ->
  IO.puts("  #{f.control_id}: #{f.status} (#{inspect(f.severity)}) #{inspect(f.explanation)}")
end)

# 5. The subject-facing calculations
[loaded] =
  AshEnterprise.Accounts.ProjectedUser
  |> Ash.Query.filter(login == ^"kycdemo#{leg_id}")
  |> Ash.Query.load([:kyc_status, :compliant?, :gap_count])
  |> Ash.read!(authorize?: false, tenant: org)

IO.puts(
  "kyc_status=#{inspect(loaded.kyc_status)} compliant?=#{inspect(loaded.compliant?)} gap_count=#{loaded.gap_count}"
)

# 6. Evaluations: the auditor's truth
evals =
  AshCompliance.Resources.ComplianceEvaluation
  |> Ash.Query.filter(organization_id == ^org and subject_id == ^subject_id_str)
  |> Ash.read!(authorize?: false)

IO.puts(
  "evaluations: #{length(evals)}; sample outcome=#{inspect(hd(evals).outcome)} bundle=#{String.slice(hd(evals).bundle_hash, 0, 12)}"
)
