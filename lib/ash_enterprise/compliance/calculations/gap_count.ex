defmodule AshEnterprise.Compliance.Calculations.GapCount do
  @moduledoc """
  How many controls the subject is currently breaching — the count of
  noncompliant findings on the subject's grain. Zero findings is zero gaps;
  the subject simply has not been evaluated.

  Shares the batched query contract with `KycStatus`: one read per
  `calculate/2` across every record, under the package interface's documented
  trusted-machinery bypass (see that module for the authorization argument).
  """

  use Ash.Resource.Calculation

  import Ash.Expr, only: [expr: 1]

  @impl true
  def load(_query, _opts, _context), do: [:organization_id, :legacy_id]

  @impl true
  def calculate(records, _opts, _context) do
    organization_ids = records |> MapSet.new(& &1.organization_id) |> MapSet.to_list()

    subject_ids =
      records
      |> MapSet.new(fn record ->
        record.legacy_id && Integer.to_string(record.legacy_id)
      end)
      |> MapSet.to_list()
      |> Enum.reject(&is_nil/1)

    breaches =
      if subject_ids == [] do
        %{}
      else
        AshCompliance.Domain.list_findings!(
          query: [
            filter:
              expr(
                organization_id in ^organization_ids and subject_type == "user" and
                  subject_id in ^subject_ids and status == :noncompliant
              )
          ],
          authorize?: false
        )
        |> Enum.frequencies_by(&{&1.organization_id, &1.subject_id})
      end

    Enum.map(records, fn record ->
      subject_id = record.legacy_id && Integer.to_string(record.legacy_id)

      case subject_id do
        nil -> 0
        subject_id -> Map.get(breaches, {record.organization_id, subject_id}, 0)
      end
    end)
  end
end
