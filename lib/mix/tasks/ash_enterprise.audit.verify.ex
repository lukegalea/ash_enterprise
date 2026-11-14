defmodule Mix.Tasks.AshEnterprise.Audit.Verify do
  @shortdoc "Verifies the audit log's hash chains and reports the first break"

  @moduledoc """
  Walks every chain in the audit log and reports where, if anywhere, it stops
  adding up.

      mix ash_enterprise.audit.verify
      mix ash_enterprise.audit.verify --tenant 0198f3a4-...

  Exits non-zero when any chain has a finding, so it can be a scheduled check
  rather than something someone remembers to run. The check itself is
  `AshEnterprise.Audit.Verify`, which a release runs as
  `AshEnterprise.Release.audit_verify/2`.
  """

  use Mix.Task

  alias AshEnterprise.Audit.Verify
  alias AshEnterprise.Mix.Helpers

  @requirements ["app.config"]

  @doc """
  The SOC 2 criteria this module records evidence for (the chain verification).

  Read by `AshCompliance.Ownership.Resolver.proves_producer/2`; `docs/controls.json`
  rows that name this module as their evidence producer must appear here.
  """
  def evidence_controls, do: ["CC4.1", "CC7.2"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [tenant: :string])

    # Reads `audit_event_logs` through plain SQL. No Oban, no endpoint, no
    # projectors -- and none wanted: a verifier must not drain the queues it is
    # checking (iron law #23; docs/reviews/iron-law-audit.md, fix item 3).
    Helpers.boot_repo()

    report = Verify.report(opts[:tenant])
    Enum.each(Verify.lines(report), &print(&1, report.status))

    if report.status == :broken, do: exit({:shutdown, 1})
  end

  defp print(line, :broken), do: Mix.shell().error(line)
  defp print(line, :ok), do: Mix.shell().info(line)
end
