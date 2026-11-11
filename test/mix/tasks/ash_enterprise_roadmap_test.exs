defmodule Mix.Tasks.AshEnterprise.RoadmapTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.AshEnterprise.Roadmap

  defp question(id, text), do: %{"id" => id, "question" => text, "status" => "open"}

  test "the committed ledger passes validation" do
    %{"questions" => questions, "items" => items} =
      "docs/roadmap.json" |> File.read!() |> Jason.decode!()

    assert Roadmap.validate!(questions, items) == :ok
  end

  test "a question asked twice under two ids is refused, whatever the punctuation" do
    questions = [
      question(
        "q52",
        "How are business rules expressed, versioned, and changed without a deploy?"
      ),
      question("q53", "How are business rules expressed, versioned and changed without a deploy?")
    ]

    assert_raise Mix.Error, ~r/Duplicate question .*"q52", "q53"/, fn ->
      Roadmap.validate!(questions, [])
    end
  end

  test "a reused question id is refused" do
    questions = [question("q1", "Who owns a record?"), question("q1", "Who may read it?")]

    assert_raise Mix.Error, ~r/Duplicate question id/, fn ->
      Roadmap.validate!(questions, [])
    end
  end

  test "a reused roadmap item id is refused" do
    items = [%{"id" => "decisions"}, %{"id" => "decisions"}]

    assert_raise Mix.Error, ~r/Duplicate roadmap item id/, fn ->
      Roadmap.validate!([], items)
    end
  end

  test "distinct questions pass" do
    questions = [question("q1", "Who owns a record?"), question("q2", "Who may read it?")]
    assert Roadmap.validate!(questions, []) == :ok
  end

  describe "a shipped row names its test" do
    @this_file "test/mix/tasks/ash_enterprise_roadmap_test.exs"

    defp shipped(fields),
      do:
        Map.merge(
          %{"id" => "q1", "question" => "Who owns a record?", "status" => "shipped"},
          fields
        )

    test "a shipped row with no test is refused" do
      assert_raise Mix.Error, ~r/"q1" is shipped but does not name its test/, fn ->
        Roadmap.validate!([shipped(%{"proof" => @this_file})], [])
      end
    end

    test "a cited test that is not in its file is refused" do
      assert_raise Mix.Error, ~r/not in #{@this_file}. Was it renamed\?/, fn ->
        Roadmap.validate!(
          [shipped(%{"proof" => @this_file, "test" => "a test nobody " <> "wrote"})],
          []
        )
      end
    end

    test "a cited file that does not exist is refused" do
      assert_raise Mix.Error, ~r/which is not a file/, fn ->
        Roadmap.validate!([shipped(%{"proof" => "test/no_such_test.exs", "test" => "x"})], [])
      end
    end

    test "a test named in its file passes" do
      row = shipped(%{"proof" => @this_file, "test" => "a test named in its file passes"})
      assert Roadmap.validate!([row], []) == :ok
    end
  end
end
