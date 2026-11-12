defmodule Mix.Tasks.AshEnterprise.Audit.Export do
  @shortdoc "Writes the audit package for one tenant and period to a directory"

  @moduledoc """
  The audit package an auditor is handed, for one tenant and one period.

      mix ash_enterprise.audit.export --tenant 0198f3a4-... --as auditor@example.com \\
        --from 2026-01-01 --to 2027-01-01 --out tmp/audit-2026

  Dates are ISO-8601 and the period is half-open: `--to` is excluded, so consecutive
  periods do not double-count the boundary.

  `--as` names the person exporting. They must be a member of `--tenant` and hold the
  auditor privilege (`read` on `AshEnterprise.Audit.Package`, at `:global`); without it
  the task stops and writes nothing. There is no export as the system and none across
  tenants.

  The directory receives:

    * `assessment-results.json` — OSCAL 1.2.3 assessment results;
    * `controls.json` — the criteria in scope and the control file's row for each;
    * `evidence.json` — the evidence collected in the period and each criterion's
      freshness at its end;
    * `findings.json` — the compliance findings open in the period;
    * `reviews.json` — the review tasks touched in the period and their outcomes;
    * `chain.json` — the audit chain's verification. `"status": "broken"` when it does
      not verify, and the task says so;
    * `events.csv` — the audit trail of the period in chain order, read as `--as`
      (`AshEnterprise.Audit.Export`), with `sequence`, `previous_hash` and `hash`;
    * `manifest.json` — what was exported, by whom, and the SHA-256 of every file.

  See `AshEnterprise.Audit.Package`.
  """

  use Mix.Task

  require Ash.Query

  alias AshEnterprise.Audit.Export
  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.Security.ActorContext

  @requirements ["app.config"]

  @documents [
    {"assessment_results", "assessment-results.json"},
    {"controls", "controls.json"},
    {"evidence", "evidence.json"},
    {"findings", "findings.json"},
    {"reviews", "reviews.json"},
    {"chain", "chain.json"}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [tenant: :string, as: :string, from: :string, to: :string, out: :string]
      )

    tenant = opts[:tenant] || Mix.raise("--tenant is required (the organization id)")
    email = opts[:as] || Mix.raise("--as is required (the exporting person's email)")
    from = parse_date!(opts[:from], "--from")
    to = parse_date!(opts[:to], "--to")
    dir = opts[:out] || Mix.raise("--out is required (a directory)")

    # A read through Ash against the Repo: nothing in the supervision tree (iron law #23).
    Helpers.boot_repo()

    # The trail can hold events about any resource, and each row's stored `action` only
    # deserializes once the resource defining it is loaded.
    Helpers.load_domain_resources()

    actor = person!(tenant, email)

    case AshEnterprise.Audit.export_audit_package(from, to, actor: actor, tenant: tenant) do
      {:ok, package} ->
        %{"chain" => chain} = package = write!(dir, package, from, to, actor, tenant)
        report(dir, package, chain)

      {:error, %Ash.Error.Forbidden{}} ->
        Mix.raise(
          "#{email} does not hold the auditor privilege in #{tenant}; nothing was written"
        )

      {:error, error} ->
        Mix.raise("the audit package could not be built: #{Exception.message(error)}")
    end
  end

  @doc false
  @spec write!(Path.t(), map(), DateTime.t(), DateTime.t(), term(), String.t()) :: map()
  def write!(dir, package, from, to, actor, tenant) do
    File.mkdir_p!(dir)

    hashes =
      for {key, name} <- @documents, into: %{} do
        {name, write_file!(dir, name, Jason.encode_to_iodata!(package[key], pretty: true))}
      end

    {events_hash, rows} = write_events!(dir, from, to, actor, tenant)

    manifest =
      package["manifest"]
      |> Map.put("files", Map.put(hashes, "events.csv", events_hash))
      |> Map.put("events_csv", %{
        "rows" => rows,
        "events_in_period" => package["chain"]["events_in_period"],
        "complete" => rows == package["chain"]["events_in_period"]
      })

    write_file!(dir, "manifest.json", Jason.encode_to_iodata!(manifest, pretty: true))
    Map.put(package, "manifest", manifest)
  end

  defp write_file!(dir, name, iodata) do
    File.write!(Path.join(dir, name), iodata)
    iodata |> IO.iodata_to_binary() |> sha256()
  end

  # Read as the exporter, so the trail is exactly as wide as their own grant on the log.
  # The manifest compares its rows with the period's count, so a narrower grant shows.
  defp write_events!(dir, from, to, actor, tenant) do
    lines = from |> Export.stream(to, actor: actor, tenant: tenant) |> Enum.to_list()
    hash = write_file!(dir, "events.csv", lines)
    {hash, length(lines) - 1}
  end

  defp report(dir, package, chain) do
    manifest = package["manifest"]
    criteria = length(package["controls"]["criteria"])
    tasks = length(package["reviews"]["tasks"])
    findings = length(package["findings"]["findings"])

    Mix.shell().info([
      :green,
      "Wrote the audit package to #{dir}",
      :reset,
      "\n  period: #{manifest["period"]["from"]} .. #{manifest["period"]["to"]} (exclusive)",
      "\n  tenant: #{manifest["tenant"]}",
      "\n  criteria: #{criteria}, findings: #{findings}, review tasks: #{tasks}",
      "\n  events: #{manifest["events_csv"]["rows"]} of #{chain["events_in_period"]}"
    ])

    if chain["status"] == "broken" do
      Mix.shell().error(
        "The audit chain is BROKEN: #{length(chain["findings"])} finding(s), " <>
          "#{chain["findings_in_period"]} in the period. See chain.json."
      )
    end
  end

  # The person `--as` names, with their context attached, when they are a member of the
  # tenant: a user is not tenant-scoped, so finding one by email says nothing about which
  # tenant they belong to, and their context is built for the tenant that owns them.
  defp person!(tenant, email) do
    AshEnterprise.Accounts.User
    |> Ash.Query.filter(email == ^email)
    # Looking the person up is not acting as them: who they are has to be known before
    # any of their authority can be.
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil ->
        Mix.raise("no user with the email #{email}")

      user ->
        context = ActorContext.build(user)

        if to_string(context.organization_id) == tenant,
          do: ActorContext.attach(user, context),
          else: Mix.raise("#{email} is not a member of #{tenant}")
    end
  end

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  defp parse_date!(nil, flag), do: Mix.raise("#{flag} is required (ISO-8601, e.g. 2026-08-01)")

  defp parse_date!(value, flag) do
    case DateTime.from_iso8601(value <> "T00:00:00Z") do
      {:ok, datetime, _} ->
        datetime

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _} -> datetime
          _ -> Mix.raise("#{flag} is not an ISO-8601 date or datetime: #{value}")
        end
    end
  end
end
