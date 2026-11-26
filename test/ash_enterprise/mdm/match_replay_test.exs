defmodule AshEnterprise.Mdm.MatchReplayTest do
  @moduledoc """
  S1-84: a candidate rule set replayed over the pairs stewards decided, beside
  the rules it would replace. The counts are exact on a fixture whose every
  score can be worked by hand, banded here by the seed table's ranges.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Mdm.MatchReplay

  @rules [
    %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0},
    %{
      "name" => "name_fuzzy",
      "kind" => "fuzzy",
      "field" => "name",
      "algorithm" => "jaro",
      "weight" => 1.0
    }
  ]

  # The seed table's ranges (`priv/dmn/mdm_match_bands.dmn`), for a pure test.
  defp band(score) do
    cond do
      Decimal.compare(score, "0.9") != :lt -> {:ok, :admit}
      Decimal.compare(score, "0.5") != :lt -> {:ok, :review}
      true -> {:ok, :omit}
    end
  end

  defp explanation(email, name) do
    %{
      "email_exact" => %{"w" => "1.0", "c" => email},
      "name_fuzzy" => %{"w" => "1.0", "c" => name}
    }
  end

  defp verdicts(spec) do
    for {verdict, email, name, count} <- spec, _ <- 1..count do
      %{id: Ash.UUID.generate(), verdict: verdict, explanation: explanation(email, name)}
    end
  end

  # 12 confirmed: the email always agrees, the name in half. 12 rejected: the
  # email never agrees, the name in 8. Tuning learns that the email is the
  # evidence and floors the name.
  defp fixture do
    verdicts([
      {:match, "1", "1", 6},
      {:match, "1", "0.5", 6},
      {:non_match, "0", "1", 8},
      {:non_match, "0", "0", 4}
    ])
  end

  defp proposed(verdicts), do: AshMdm.Tuning.propose(@rules, verdicts).rules

  test "re-scores an explanation the way the matcher folds it" do
    rules = [
      %{"name" => "email_exact", "weight" => 3.0},
      %{"name" => "name_fuzzy", "weight" => 1.0}
    ]

    assert MatchReplay.score(rules, explanation("1", "0.5")) |> Decimal.equal?("0.875")
    # A missing weight counts 1, as in `AshMdm.Match.score/3`.
    assert MatchReplay.score(
             [%{"name" => "email_exact"}, %{"name" => "name_fuzzy"}],
             explanation("1", "0")
           )
           |> Decimal.equal?("0.5")
  end

  test "the counts are exact" do
    verdicts = fixture()
    after_rules = proposed(verdicts)

    assert Enum.map(after_rules, & &1["weight"]) == [4.6439, 0.01]

    assert {:ok, %{summary: summary, changed: changed}} =
             MatchReplay.replay(@rules, after_rules, verdicts, &band/1)

    assert Map.take(summary, ~w(verdicts replayed skipped changed toward_admit toward_omit flips)) ==
             %{
               "verdicts" => 24,
               "replayed" => 24,
               "skipped" => 0,
               "changed" => 14,
               "toward_admit" => 6,
               "toward_omit" => 8,
               "flips" => 0
             }

    # Active: the half-name confirms (0.75) and the name-only rejects (0.5) wait in review.
    assert summary["before"] == %{
             "admit" => 6,
             "review" => 14,
             "omit" => 4,
             "agree" => 10,
             "disagree" => 0,
             "precision" => "1.0000",
             "recall" => "0.5000"
           }

    assert summary["after"] == %{
             "admit" => 12,
             "review" => 0,
             "omit" => 12,
             "agree" => 24,
             "disagree" => 0,
             "precision" => "1.0000",
             "recall" => "1.0000"
           }

    assert Enum.frequencies_by(changed, &{&1["verdict"], &1["before"], &1["after"]}) == %{
             {"match", "review", "admit"} => 6,
             {"non_match", "review", "omit"} => 8
           }

    assert Enum.all?(changed, &(&1["flip"] == false))
  end

  test "a pair scored by other rules is skipped, never replayed with a guess" do
    other = %{
      id: Ash.UUID.generate(),
      verdict: :match,
      explanation: %{"rules" => [%{"rule" => "email_exact"}]}
    }

    verdicts = fixture()

    assert {:ok, %{summary: summary}} =
             MatchReplay.replay(@rules, proposed(verdicts), [other | verdicts], &band/1)

    assert {summary["verdicts"], summary["replayed"], summary["skipped"]} == {25, 24, 1}
  end

  test "a change that undoes a steward's confirm is a flip" do
    # Two confirms the email disagrees on: a steward matched them on the name.
    flipped = verdicts([{:match, "0", "1", 2}])
    verdicts = fixture() ++ flipped

    assert {:ok, %{summary: summary, changed: changed}} =
             MatchReplay.replay(@rules, proposed(verdicts), verdicts, &band/1)

    assert {summary["changed"], summary["flips"]} == {16, 2}

    assert changed |> Enum.filter(& &1["flip"]) |> Enum.map(& &1["candidate_id"]) |> Enum.sort() ==
             flipped |> Enum.map(& &1.id) |> Enum.sort()

    assert Enum.all?(
             Enum.filter(changed, & &1["flip"]),
             &({&1["before"], &1["after"]} == {"review", "omit"})
           )
  end

  test "a precision with nothing admitted is none, not zero" do
    verdicts = verdicts([{:non_match, "0", "0", 1}])

    assert {:ok, %{summary: %{"before" => before}}} =
             MatchReplay.replay(@rules, @rules, verdicts, &band/1)

    assert {before["precision"], before["recall"]} == {nil, nil}
  end

  test "a band table that cannot answer fails the replay" do
    assert {:error, :no_table} =
             MatchReplay.replay(@rules, @rules, fixture(), fn _score -> {:error, :no_table} end)
  end
end
