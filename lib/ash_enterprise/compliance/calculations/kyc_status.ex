defmodule AshEnterprise.Compliance.Calculations.KycStatus do
  @moduledoc """
  The subject's overall KYC status, read off the finding projection.

  Worst-wins across the subject's findings, with no findings meaning `nil` —
  the subject has not been evaluated, which is a different thing from
  compliant and must read as such on any surface.

  One query per `calculate/2`, not one per record: the calculation loads over
  a list, and a finding lookup per row would be an N+1 wearing a calculation's
  clothes. The reads run under `authorize?: false` because a calculation
  cannot narrow its caller's query — the surface that renders the attribute
  has already authorized the row, and the finding grain is keyed by this very
  record's organization.
  """

  use Ash.Resource.Calculation

  import Ash.Expr, only: [expr: 1]

  @impl true
  def load(_query, _opts, _context), do: [:organization_id, :legacy_id]

  @impl true
  def calculate(records, _opts, _context) do
    findings = findings_by_subject(records)

    Enum.map(records, fn record ->
      record
      |> subject_id()
      |> then(&Map.get(findings, &1, []))
      |> case do
        [] -> nil
        findings -> worst(findings)
      end
    end)
  end

  defp findings_by_subject(records) do
    organization_ids = records |> MapSet.new(& &1.organization_id) |> MapSet.to_list()

    subject_ids =
      records |> MapSet.new(&subject_id/1) |> MapSet.to_list() |> Enum.reject(&is_nil/1)

    if subject_ids == [] do
      %{}
    else
      AshCompliance.Domain.list_findings!(
        query: [
          filter:
            expr(
              organization_id in ^organization_ids and subject_type == "user" and
                subject_id in ^subject_ids
            )
        ],
        authorize?: false
      )
      |> Enum.group_by(& &1.subject_id)
    end
  end

  defp subject_id(record), do: record.legacy_id && Integer.to_string(record.legacy_id)

  defp worst(findings) do
    findings
    |> Enum.map(& &1.status)
    |> Enum.reduce(nil, fn status, acc ->
      if acc == nil do
        status
      else
        worse(acc, status)
      end
    end)
  end

  defp worse(:error, _), do: :error
  defp worse(_, :error), do: :error
  defp worse(:noncompliant, _), do: :noncompliant
  defp worse(_, :noncompliant), do: :noncompliant
  defp worse(:unknown, _), do: :unknown
  defp worse(_, :unknown), do: :unknown
  defp worse(_, status), do: status
end
