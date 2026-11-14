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

  alias AshEnterprise.Audit.Package.Files
  alias AshEnterprise.Mix.Helpers

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [tenant: :string, as: :string, from: :string, to: :string, out: :string]
      )

    # A read through Ash against the Repo: nothing in the supervision tree (iron law #23).
    Helpers.boot_repo()

    # The trail can hold events about any resource, and each row's stored `action` only
    # deserializes once the resource defining it is loaded.
    Helpers.load_domain_resources()

    case Files.export(opts) do
      {:ok, package} ->
        {info, errors} = Files.summary(opts[:out], package)
        Mix.shell().info([:green, hd(info), :reset, "\n", Enum.join(tl(info), "\n")])
        Enum.each(errors, fn line -> Mix.shell().error(line) end)

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
