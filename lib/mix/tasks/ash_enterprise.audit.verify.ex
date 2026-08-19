defmodule Mix.Tasks.AshEnterprise.Audit.Verify do
  @shortdoc "Verifies the audit log's hash chains and reports the first break"

  @moduledoc """
  Walks every chain in the audit log and reports where, if anywhere, it stops
  adding up.

      mix ash_enterprise.audit.verify
      mix ash_enterprise.audit.verify --tenant 0198f3a4-...

  Exits non-zero when any chain has a finding, so it can be a scheduled check
  rather than something someone remembers to run. See `AshEnterprise.Audit.Chain`
  for what each kind of finding means and why rows predating the chain are
  skipped rather than reported.
  """

  use Mix.Task

  alias AshEnterprise.Audit.Chain

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [tenant: :string])

    results =
      case opts[:tenant] do
        nil -> Chain.verify_all()
        tenant -> [Chain.verify(tenant)]
      end

    Enum.each(results, &report/1)

    total = results |> Enum.flat_map(& &1.findings) |> length()

    if total == 0 do
      Mix.shell().info([
        :green,
        "\n#{Enum.sum(Enum.map(results, & &1.checked))} events across " <>
          "#{length(results)} chain(s) verified. No breaks.",
        :reset
      ])
    else
      Mix.shell().error("\n#{total} finding(s). The audit log has been modified.")
      exit({:shutdown, 1})
    end
  end

  defp report(%{organization_id: org, checked: checked} = result) do
    Mix.shell().info("\nChain #{org || "(no tenant)"} — #{checked} event(s) checked")

    if result.skipped_unchained_prefix > 0 do
      Mix.shell().info([
        :yellow,
        "  #{result.skipped_unchained_prefix} event(s) predate the chain and were skipped.",
        :reset
      ])
    end

    Enum.each(result.findings, fn f ->
      Mix.shell().error("  seq #{f.sequence}  #{f.problem}  #{f.id}  #{f.occurred_at}")
    end)
  end
end
