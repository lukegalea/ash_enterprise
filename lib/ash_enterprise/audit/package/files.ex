defmodule AshEnterprise.Audit.Package.Files do
  @moduledoc """
  Writes the audit package for one tenant and period to a directory: the body of
  `mix ash_enterprise.audit.export` and `AshEnterprise.Release.audit_export/1`, so a release,
  which has no Mix, can produce the same files. The directory's contents are listed on the
  Mix task.

  `export/1` takes the person exporting by email, who must be a member of the tenant and hold
  the auditor privilege; it never exports as the system or across tenants.
  """

  require Ash.Query

  alias AshEnterprise.Audit.Export
  alias AshEnterprise.Security.ActorContext

  # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps the compiler
  # from calling it unused (see `AshEnterprise.Audit.Export`).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @documents [
    {"assessment_results", "assessment-results.json"},
    {"controls", "controls.json"},
    {"evidence", "evidence.json"},
    {"findings", "findings.json"},
    {"reviews", "reviews.json"},
    {"chain", "chain.json"}
  ]

  @type opts :: [
          tenant: String.t(),
          as: String.t(),
          from: String.t(),
          to: String.t(),
          out: String.t()
        ]

  @doc """
  Builds and writes the package. `{:ok, package}` (with the manifest as written) or
  `{:error, message}`, in which case nothing was written. Dates are ISO-8601 and the period
  is half-open. The caller has booted the repo and loaded the domain resources.
  """
  @spec export(opts()) :: {:ok, map()} | {:error, String.t()}
  def export(opts) do
    with {:ok, tenant} <- required(opts, :tenant, "the organization id"),
         {:ok, email} <- required(opts, :as, "the exporting person's email"),
         {:ok, from} <- parse_date(opts[:from], "from"),
         {:ok, to} <- parse_date(opts[:to], "to"),
         {:ok, dir} <- required(opts, :out, "a directory"),
         {:ok, actor} <- person(tenant, email) do
      case AshEnterprise.Audit.export_audit_package(from, to, actor: actor, tenant: tenant) do
        {:ok, package} ->
          {:ok, write!(dir, package, from, to, actor, tenant)}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "#{email} does not hold the auditor privilege in #{tenant}; nothing was written"}

        {:error, error} ->
          {:error, "the audit package could not be built: #{Exception.message(error)}"}
      end
    end
  end

  defp required(opts, key, what) do
    case opts[key] do
      nil -> {:error, "#{key} is required (#{what})"}
      value -> {:ok, value}
    end
  end

  # Sobelow cannot prove the directory constant, and it is not: this writes where the
  # operator tells it, from a Mix task or a release command run on their own host (the
  # same sense in which `AshEnterprise.Audit.Export.to_file/4` is skipped). A web request
  # reaching it would be a real finding, which is why the skip is by name and local.
  @sobelow_skip ["Traversal.FileModule"]
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

  # As `write!/6`. Sobelow cannot prove the directory constant, and it is not: this writes where the
  # operator tells it, from a Mix task or a release command run on their own host (the
  # same sense in which `AshEnterprise.Audit.Export.to_file/4` is skipped). A web request
  # reaching it would be a real finding, which is why the skip is by name and local.
  @sobelow_skip ["Traversal.FileModule"]
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

  @doc "The lines that say what was written, and whether the chain is broken."
  @spec summary(Path.t(), map()) :: {[String.t()], [String.t()]}
  def summary(dir, package) do
    chain = package["chain"]
    manifest = package["manifest"]
    criteria = length(package["controls"]["criteria"])
    tasks = length(package["reviews"]["tasks"])
    findings = length(package["findings"]["findings"])

    info = [
      "Wrote the audit package to #{dir}",
      "  period: #{manifest["period"]["from"]} .. #{manifest["period"]["to"]} (exclusive)",
      "  tenant: #{manifest["tenant"]}",
      "  criteria: #{criteria}, findings: #{findings}, review tasks: #{tasks}",
      "  events: #{manifest["events_csv"]["rows"]} of #{chain["events_in_period"]}"
    ]

    errors =
      if chain["status"] == "broken",
        do: [
          "The audit chain is BROKEN: #{length(chain["findings"])} finding(s), " <>
            "#{chain["findings_in_period"]} in the period. See chain.json."
        ],
        else: []

    {info, errors}
  end

  # The person `--as` names, with their context attached, when they are a member of the
  # tenant: a user is not tenant-scoped, so finding one by email says nothing about which
  # tenant they belong to, and their context is built for the tenant that owns them.
  defp person(tenant, email) do
    AshEnterprise.Accounts.User
    |> Ash.Query.filter(email == ^email)
    # Looking the person up is not acting as them: who they are has to be known before
    # any of their authority can be.
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil ->
        {:error, "no user with the email #{email}"}

      user ->
        context = ActorContext.build(user)

        if to_string(context.organization_id) == tenant,
          do: {:ok, ActorContext.attach(user, context)},
          else: {:error, "#{email} is not a member of #{tenant}"}
    end
  end

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  defp parse_date(nil, name),
    do: {:error, "--#{name} is required (ISO-8601, e.g. 2026-08-01)"}

  defp parse_date(value, name) do
    with :error <- iso(value <> "T00:00:00Z"),
         :error <- iso(value) do
      {:error, "--#{name} is not an ISO-8601 date or datetime: #{value}"}
    end
  end

  defp iso(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> {:ok, datetime}
      _ -> :error
    end
  end
end
