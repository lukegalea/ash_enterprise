defmodule AshEnterprise.Licences.EvalSet do
  @moduledoc """
  A licence family's eval set (S1-63/AC-1): the model's recorded answers
  about declared subjects, each paired with the declaration rung's answer
  as gold. One per calibrated family (`families/0`): `third_party_licence`,
  and `licence_use_restriction`, the use-restriction question's own.

  A calibration pass asks the model about subjects whose declaration
  already settles the questions (`AshEnterprise.Licences.Rungs.judge/3` with
  `calibration?: true`). Every answer is an observation in the judgment
  ledger. `build/2` reads those observations back (law 2: record, don't
  recompute), keeps the latest per subject and question, and labels each
  with the subject's routed answer. A question the route left pending (an
  Apache-2.0 NOTICE check with no package contents) has no gold and is left
  out, and so is a subject that is not on the declaration rung.

  Pairs are the questions the family declares now, read by question rather
  than by the family a ledger row was recorded under. A question that
  moved family keeps its judgments in its new family's eval set (the
  use-restriction question's rows, recorded under `third_party_licence`
  before 2026-11-21), and an older row for a question that left the family
  (the declaration question, which never calibrates) is not a pair.

  The document is what `AshEnterprise.SystemOne.CalibrationInput` reads.
  """

  require Ash.Query

  alias AshEnterprise.Licences.Dependency
  alias AshEnterprise.Licences.Rungs
  alias AshEnterprise.SystemOne.Judgment
  alias AshJudgments.Registry.Info

  @subject_type "licence_dependency"

  @doc "The calibrated licence families: the families of the model questions."
  @spec families() :: [String.t()]
  def families do
    Dependency
    |> Info.questions()
    |> Enum.filter(&(&1.name in Rungs.model_questions()))
    |> Enum.map(&Atom.to_string(&1.family))
    |> Enum.uniq()
  end

  @doc """
  Builds the eval-set document for one family's calibration observations
  in one tenant.

  Options: `:actor` (a system actor; required), `:tenant` (required),
  `:family` (one of `families/0`; default `"third_party_licence"`),
  `:questions` (narrow to some of the family's question names; default all
  of them) and `:created_by`. A family that is not calibrated raises.
  """
  @spec build(keyword()) :: map()
  def build(opts) do
    actor = Keyword.fetch!(opts, :actor)
    tenant = Keyword.fetch!(opts, :tenant)
    family = Keyword.get(opts, :family, "third_party_licence")
    family_questions = questions(family)

    wanted =
      opts
      |> Keyword.get(:questions, Enum.map(family_questions, & &1.name))
      |> MapSet.new(&to_string/1)

    question_ids =
      for question <- family_questions,
          MapSet.member?(wanted, Atom.to_string(question.name)),
          do: question.question_id

    subjects =
      Dependency
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)
      |> Ash.read!()
      |> Map.new(&{&1.id, &1})

    observations =
      Judgment
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)
      |> Ash.Query.filter(subject_type == ^@subject_type and question_id in ^question_ids)
      |> Ash.Query.sort(recorded_at: :asc)
      |> Ash.read!()
      |> Enum.filter(&calibration?/1)
      # The latest observation per subject and question wins.
      |> Map.new(&{{&1.subject_id, &1.question_id}, &1})
      |> Map.values()
      |> Enum.sort_by(&{&1.subject_id, &1.question_id})

    names = Map.new(Rungs.questions(), &{Atom.to_string(&1), &1})

    pairs =
      Enum.flat_map(observations, fn observation ->
        with %Dependency{} = subject <- Map.get(subjects, observation.subject_id),
             %{rung: :declaration, answers: answers} <- Rungs.route(subject),
             gold when is_boolean(gold) <-
               Map.get(answers, Map.get(names, question_name(observation))) do
          [
            %{
              "p" => probability_true(observation),
              "gold" => gold,
              "question" => question_name(observation),
              "question_hash" => observation.question_hash,
              "observation_id" => observation.id,
              "package" => subject.package,
              "version" => subject.version
            }
          ]
        else
          _no_gold -> []
        end
      end)

    %{
      "family" => family,
      "answer_kind" => "noul",
      "question_hashes" => pairs |> Enum.map(& &1["question_hash"]) |> Enum.uniq() |> Enum.sort(),
      "model_version" => single(observations, :model_version),
      "model_digest" => single(observations, :model_digest),
      "runtime_version" => single(observations, :runtime_version),
      "region" => single(observations, :region),
      "tenant" => to_string(tenant),
      "created_by" => Keyword.get(opts, :created_by, inspect(__MODULE__)),
      "observations_digest" => digest(Enum.map(pairs, & &1["observation_id"])),
      "pairs" => pairs
    }
  end

  defp questions(family) do
    unless family in families() do
      raise ArgumentError,
            "#{inspect(family)} is not a calibrated licence family (#{Enum.join(families(), ", ")})"
    end

    Dependency
    |> Info.questions()
    |> Enum.filter(&(Atom.to_string(&1.family) == family))
  end

  defp calibration?(observation) do
    match?(%{"purpose" => "calibration"}, observation.state_ref)
  end

  defp question_name(observation) do
    observation.question_id |> String.split("#judgments/") |> List.last()
  end

  defp probability_true(%{probabilities: %{"true" => p}}), do: decimal_float(p)

  defp decimal_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_float(p) when is_binary(p), do: p |> Decimal.new() |> Decimal.to_float()
  defp decimal_float(p) when is_number(p), do: p / 1

  defp single(observations, field) do
    case observations |> Enum.map(&Map.get(&1, field)) |> Enum.uniq() do
      [value] -> value
      [] -> nil
      values -> raise ArgumentError, "eval set mixes #{field} values: #{inspect(values)}"
    end
  end

  defp digest(ids) do
    "sha256:" <>
      Base.encode16(:crypto.hash(:sha256, Enum.join(ids, "\n")), case: :lower)
  end
end
