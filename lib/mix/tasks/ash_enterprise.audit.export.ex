defmodule Mix.Tasks.AshEnterprise.Audit.Export do
  @shortdoc "Exports a window of the audit log as CSV"

  @moduledoc """
  The evidence sample an auditor asks for.

      mix ash_enterprise.audit.export --from 2026-08-01 --to 2026-09-01
      mix ash_enterprise.audit.export --from 2026-08-01 --to 2026-08-08 \\
        --tenant 0198f3a4-... --out tmp/acme-august.csv

  Dates are ISO-8601, and the window is half-open — `--to` is excluded, so
  consecutive months do not double-count the boundary.

  Without `--tenant` the export spans every tenant. That is occasionally what an
  internal investigation wants and never what a customer's auditor should
  receive, so it is a flag rather than a default. See `AshEnterprise.Audit.Export`
  for why the integrity columns are included.
  """

  use Mix.Task

  alias AshEnterprise.Audit.Export
  alias AshEnterprise.Platform.SystemActor

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [from: :string, to: :string, tenant: :string, out: :string]
      )

    from = parse_date!(opts[:from], "--from")
    to = parse_date!(opts[:to], "--to")

    path = opts[:out] || default_path(from, to, opts[:tenant])

    count =
      Export.to_file(path, from, to,
        actor: SystemActor.system(),
        tenant: opts[:tenant]
      )

    Mix.shell().info([
      :green,
      "Wrote #{count} event(s) to #{path}",
      :reset,
      "\n  window: #{DateTime.to_iso8601(from)} .. #{DateTime.to_iso8601(to)} (exclusive)",
      "\n  tenant: #{opts[:tenant] || "all tenants"}"
    ])
  end

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

  defp default_path(from, to, tenant) do
    scope = if tenant, do: String.slice(tenant, 0, 8), else: "all-tenants"

    Path.join(
      "tmp",
      "audit-#{scope}-#{Date.to_iso8601(DateTime.to_date(from))}-to-#{Date.to_iso8601(DateTime.to_date(to))}.csv"
    )
  end
end
