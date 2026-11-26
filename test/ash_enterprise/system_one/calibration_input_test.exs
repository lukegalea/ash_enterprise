defmodule AshEnterprise.SystemOne.CalibrationInputTest do
  # Writes the seam's eval-set directory into application config.
  use ExUnit.Case, async: false

  alias AshEnterprise.Licences.Dependency
  alias AshEnterprise.SystemOne.BandTablePublication.CertifyAndPublish
  alias AshEnterprise.SystemOne.CalibrationInput
  alias AshJudgments.Registry.Info

  @family "licence_weak_copyleft"

  setup do
    dir = Path.join(System.tmp_dir!(), "calibration-input-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:ash_enterprise, CalibrationInput)
    Application.put_env(:ash_enterprise, CalibrationInput, eval_set_dir: dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.put_env(:ash_enterprise, CalibrationInput, previous || [])
    end)

    %{dir: dir}
  end

  # An eval set saved before a question left the family: its pairs and
  # hashes still name it.
  test "an eval set holding a question its family no longer declares is refused", %{dir: dir} do
    weak = Info.question(Dependency, :package_licence_is_weak_copyleft)
    moved = Info.question(Dependency, :package_licence_has_use_restrictions)
    assert to_string(moved.family) != @family

    write(dir, doc([pair(weak, 0.9, true), pair(moved, 0.8, false)]))

    assert CalibrationInput.load(@family, :eval_set) ==
             {:error, {:questions_outside_family, ["package_licence_has_use_restrictions"]}}

    assert_raise ArgumentError, ~r/package_licence_has_use_restrictions/, fn ->
      bytes = File.read!(Path.join(dir, "#{@family}.eval-set.json"))
      CalibrationInput.input(Jason.decode!(bytes), bytes)
    end
  end

  # The pooled family the licence questions shared until 2026-11-21 is
  # gone: a set saved under it declares none of its questions.
  test "an eval set saved under a retired family is refused", %{dir: dir} do
    weak = Info.question(Dependency, :package_licence_is_weak_copyleft)
    moved = Info.question(Dependency, :package_licence_has_use_restrictions)
    retired = "third_party_licence"
    assert CalibrationInput.family_questions(retired) == []

    File.write!(
      Path.join(dir, "#{retired}.eval-set.json"),
      Jason.encode!(%{
        doc([pair(weak, 0.9, true), pair(moved, 0.8, false)])
        | "family" => retired
      })
    )

    assert CalibrationInput.load(retired, :eval_set) ==
             {:error,
              {:questions_outside_family,
               ["package_licence_has_use_restrictions", "package_licence_is_weak_copyleft"]}}
  end

  test "a hash the family does not declare is refused, even with no pair naming it", %{dir: dir} do
    weak = Info.question(Dependency, :package_licence_is_weak_copyleft)

    write(
      dir,
      %{
        doc([pair(weak, 0.9, true)])
        | "question_hashes" => [weak.question_hash, "sha256:unknown"]
      }
    )

    assert CalibrationInput.load(@family, :eval_set) ==
             {:error, {:questions_outside_family, ["sha256:unknown"]}}
  end

  test "an eval set of the family's own questions loads", %{dir: dir} do
    weak = Info.question(Dependency, :package_licence_is_weak_copyleft)
    write(dir, doc([pair(weak, 0.9, true), pair(weak, 0.2, false)]))

    assert {:ok, input} = CalibrationInput.load(@family, :eval_set)
    assert input.question_hashes == [weak.question_hash]
    assert length(input.pairs) == 2
  end

  test "a run's band table gates only on its own family's questions" do
    weak = Info.question(Dependency, :package_licence_is_weak_copyleft)
    moved = Info.question(Dependency, :package_licence_has_use_restrictions)

    assert CertifyAndPublish.score_inputs(%{
             family: @family,
             question_hashes: [weak.question_hash, moved.question_hash]
           }) == ["package_licence_is_weak_copyleft__p_true"]
  end

  defp pair(question, p, gold) do
    %{
      "p" => p,
      "gold" => gold,
      "question" => Atom.to_string(question.name),
      "question_hash" => question.question_hash
    }
  end

  defp doc(pairs) do
    %{
      "family" => @family,
      "answer_kind" => "noul",
      "question_hashes" => pairs |> Enum.map(& &1["question_hash"]) |> Enum.uniq() |> Enum.sort(),
      "model_version" => "synthetic-model",
      "model_digest" => "sha256:model",
      "runtime_version" => "synthetic-runtime",
      "region" => "test",
      "tenant" => "synthetic",
      "created_by" => "calibration-input-test",
      "observations_digest" => "sha256:observations",
      "pairs" => pairs
    }
  end

  defp write(dir, doc) do
    File.write!(Path.join(dir, "#{@family}.eval-set.json"), Jason.encode!(doc))
  end
end
