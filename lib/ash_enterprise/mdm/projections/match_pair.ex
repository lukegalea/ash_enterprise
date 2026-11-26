defmodule AshEnterprise.Mdm.Projections.MatchPair do
  @moduledoc """
  The `state_projection` of the match second opinion
  (`AshEnterprise.Mdm.MatchCandidate`'s `records_describe_same_entity`):
  the side-by-side the steward surface shows, the staged record's name and
  email next to the golden record's, and nothing else.

  The matcher's score and per-rule explanation are left out on purpose:
  the second opinion is a reading of the two records, not of the matcher's
  reading of them. An absent value is `""`.

  `shape/0` is part of the question's hash, so a change to what the model
  sees is a new question and `priv/judgments/lock.json` refuses it without
  a version bump.
  """

  @behaviour AshJudgments.Registry.StateProjection

  @fields [:staged_name, :staged_email, :golden_name, :golden_email]

  @impl AshJudgments.Registry.StateProjection
  def project(%{arguments: %{input: pair}}, _context), do: state(pair)
  def project(pair, _context) when is_map(pair), do: state(pair)

  @impl AshJudgments.Registry.StateProjection
  def shape, do: Map.new(@fields, &{Atom.to_string(&1), "string"})

  @doc "The state for a pair given as a map with the four fields under string or atom keys."
  @spec state(map()) :: %{String.t() => String.t()}
  def state(pair) do
    Map.new(@fields, fn field ->
      key = Atom.to_string(field)
      value = Map.get(pair, key, Map.get(pair, field))
      {key, if(is_nil(value), do: "", else: to_string(value))}
    end)
  end
end
