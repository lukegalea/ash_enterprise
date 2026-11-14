defmodule AshEnterprise.Audit.Verify do
  @moduledoc """
  Walks the audit log's hash chains and reports where, if anywhere, one stops adding up.

  The body of `mix ash_enterprise.audit.verify` and `AshEnterprise.Release.audit_verify/2`:
  a release has no Mix, so the check lives here and both are thin callers. It reads through
  `AshEvents.Chain` and writes nothing. See `AshEvents.Chain` for what each kind of finding
  means and why rows predating the chain are skipped rather than reported.
  """

  alias AshEnterprise.Audit.EventLog

  @type report :: %{
          status: :ok | :broken,
          chains: [map()],
          checked: non_neg_integer(),
          findings: non_neg_integer()
        }

  @doc "Verifies every chain, or only `tenant`'s (an organization id)."
  @spec report(String.t() | nil) :: report()
  def report(tenant \\ nil) do
    chains =
      case tenant do
        nil -> AshEvents.Chain.verify_all(EventLog)
        tenant -> [AshEvents.Chain.verify(EventLog, tenant)]
      end

    findings = chains |> Enum.flat_map(& &1.findings) |> length()

    %{
      status: if(findings == 0, do: :ok, else: :broken),
      chains: chains,
      checked: chains |> Enum.map(& &1.checked) |> Enum.sum(),
      findings: findings
    }
  end

  @doc "The report as lines of text, one block per chain and a closing verdict."
  @spec lines(report()) :: [String.t()]
  def lines(%{chains: chains} = report) do
    Enum.flat_map(chains, &chain_lines/1) ++ [verdict(report)]
  end

  defp chain_lines(%{partition: org, checked: checked} = chain) do
    skipped =
      if chain.skipped_unchained_prefix > 0,
        do: ["  #{chain.skipped_unchained_prefix} event(s) predate the chain and were skipped."],
        else: []

    ["", "Chain #{org || "(no tenant)"} -- #{checked} event(s) checked"] ++
      skipped ++
      Enum.map(chain.findings, fn f ->
        "  seq #{f.sequence}  #{f.problem}  #{f.id}  #{f.occurred_at}"
      end)
  end

  defp verdict(%{status: :ok} = report),
    do: "\n#{report.checked} events across #{length(report.chains)} chain(s) verified. No breaks."

  defp verdict(report),
    do: "\n#{report.findings} finding(s). The audit log has been modified."
end
