defmodule AshEnterprise.Mdm.Calculations.SecondOpinionText do
  @moduledoc """
  The model's second opinion on a match candidate as the steward reads it
  (S1-83): what the model said, how sure it was, and what that decides.
  Reads only the candidate's own `second_opinion` stamp
  (`AshEnterprise.Mdm.SecondOpinion`); it asks no model and reads no other
  record.

  An opinion from a band table without a certification in force is labelled
  uncalibrated, and says it decides nothing. A certified table's review
  band leaves the pair with the steward, and says so.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:second_opinion]

  @impl true
  def calculate(records, _opts, _context) do
    {:ok, Enum.map(records, &text(&1.second_opinion))}
  end

  defp text(nil), do: nil

  defp text(%{"certified" => true, "reading" => "unsure"} = opinion),
    do: "#{lean(opinion)}. Not sure enough under the certified band table: a steward decides."

  defp text(%{"certified" => true} = opinion),
    do: "#{lean(opinion)}. Admitted under the certified band table."

  defp text(opinion),
    do: "#{lean(opinion)}. Uncalibrated second opinion: it decides nothing."

  defp lean(%{"p_true" => p}) when is_number(p) do
    said = if p >= 0.5, do: "Same entity", else: "Different entities"
    "#{said} (probability of same #{:erlang.float_to_binary(p / 1, decimals: 2)})"
  end

  defp lean(_opinion), do: "No answer"
end
