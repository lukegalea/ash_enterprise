defmodule AshBrowserTests.ReporterTest do
  @moduledoc """
  The formatter exists for one reason: media files carry no outcome. So what is
  worth asserting is the key format — the join to those files — and that a
  failure's text is recorded without dragging a rendered page into a CI
  artifact.
  """

  use ExUnit.Case, async: true

  alias AshBrowserTests.Reporter

  defp test_struct(attrs) do
    struct!(
      %ExUnit.Test{module: My.AppTest, name: :"test signs in", state: nil, tags: %{}, time: 0},
      attrs
    )
  end

  defp run(tests, path) do
    {:ok, state} = Reporter.init([])

    state =
      Enum.reduce(tests, state, fn test, acc ->
        {:noreply, next} = Reporter.handle_cast({:test_finished, test}, acc)
        next
      end)

    Application.put_env(:ash_browser_tests, :report_path, path)
    on_exit(fn -> Application.delete_env(:ash_browser_tests, :report_path) end)

    {:noreply, _state} = Reporter.handle_cast({:suite_finished, %{}}, state)

    path |> File.read!() |> Jason.decode!()
  end

  defp tmp(name) do
    path = Path.join(System.tmp_dir!(), "abt-#{name}-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "key/2" do
    test "is the module and test name, with the punctuation the driver replaces" do
      # This is the contract with PhoenixTest.Playwright.Case's private
      # `file_name/2`. If it drifts, the report shows tests with no media rather
      # than crashing — which is exactly why it needs pinning here.
      assert Reporter.key(My.AppTest, :"test signs in") == "My.AppTest.test_signs_in"
    end

    test "drops the Elixir prefix an atom module carries" do
      refute Reporter.key(My.AppTest, :"test x") =~ "Elixir"
    end

    test "replaces everything outside letters, digits and dots" do
      key = Reporter.key(My.AppTest, :"test a-b/c:d (e)")

      assert key == "My.AppTest.test_a_b_c_d__e_"
      refute key =~ ~r/[^a-zA-Z0-9._]/
    end

    test "keeps the dots that separate module segments" do
      assert Reporter.key(A.B.CTest, :"test x") == "A.B.CTest.test_x"
    end

    test "a string test name works as well as an atom" do
      assert Reporter.key(My.AppTest, "test signs in") == "My.AppTest.test_signs_in"
    end
  end

  describe "the recorded run" do
    test "a pass records its key, name, module and duration" do
      %{"tests" => [recorded]} =
        run([test_struct(time: 41_200)], tmp("pass"))

      assert recorded["key"] == "My.AppTest.test_signs_in"
      assert recorded["module"] == "My.AppTest"
      assert recorded["name"] == "test signs in"
      assert recorded["status"] == "passed"
      assert recorded["time_us"] == 41_200
      assert recorded["failure"] == nil
    end

    test "a journey test records the journey and locale it ran" do
      tags = %{journey: {My.Journeys, :offboard_a_leaver, "en"}}

      %{"tests" => [journey, plain]} =
        run(
          [test_struct(tags: tags, name: :"test a"), test_struct(name: :"test b")],
          tmp("journey")
        )

      assert journey["journey"] == %{"id" => "offboard_a_leaver", "locale" => "en"}
      assert plain["journey"] == nil
    end

    test "every ExUnit state maps to a status" do
      states = [
        {nil, "passed"},
        {{:failed, [{:error, %RuntimeError{message: "boom"}, []}]}, "failed"},
        {{:invalid, My.AppTest}, "invalid"},
        {{:skipped, "later"}, "skipped"},
        {{:excluded, "tagged"}, "excluded"}
      ]

      for {{state, expected}, index} <- Enum.with_index(states) do
        %{"tests" => [recorded]} =
          run([test_struct(state: state, name: :"test #{index}")], tmp("state-#{index}"))

        assert recorded["status"] == expected
      end
    end

    test "a failure keeps its message" do
      failed = {:failed, [{:error, %RuntimeError{message: "the button was not there"}, []}]}

      %{"tests" => [recorded]} = run([test_struct(state: failed)], tmp("failed"))

      assert recorded["failure"] =~ "the button was not there"
    end

    test "a failure carrying a whole page is truncated" do
      # An ExUnit failure can hold a rendered LiveView. This file goes into a CI
      # artifact, so it is capped rather than faithful.
      huge = String.duplicate("x", 50_000)
      failed = {:failed, [{:error, %RuntimeError{message: huge}, []}]}

      %{"tests" => [recorded]} = run([test_struct(state: failed)], tmp("huge"))

      assert byte_size(recorded["failure"]) < 3_000
    end

    test "several failures on one test are all recorded" do
      failed =
        {:failed,
         [
           {:error, %RuntimeError{message: "first"}, []},
           {:error, %RuntimeError{message: "second"}, []}
         ]}

      %{"tests" => [recorded]} = run([test_struct(state: failed)], tmp("two"))

      assert recorded["failure"] =~ "first"
      assert recorded["failure"] =~ "second"
    end

    test "tests are sorted by key, so two runs of the same suite diff cleanly" do
      %{"tests" => tests} =
        run(
          [test_struct(name: :"test zeta"), test_struct(name: :"test alpha")],
          tmp("sorted")
        )

      assert Enum.map(tests, & &1["name"]) == ["test alpha", "test zeta"]
    end

    test "the file is written once, on suite_finished, not per test" do
      path = tmp("once")
      {:ok, state} = Reporter.init([])
      {:noreply, _state} = Reporter.handle_cast({:test_finished, test_struct([])}, state)

      Application.put_env(:ash_browser_tests, :report_path, path)
      on_exit(fn -> Application.delete_env(:ash_browser_tests, :report_path) end)

      # A killed run must not leave a half-written file for the report task to
      # misread as the whole truth.
      refute File.exists?(path)
    end

    test "an unrelated formatter event is ignored" do
      {:ok, state} = Reporter.init([])

      assert {:noreply, ^state} = Reporter.handle_cast({:case_started, %{}}, state)
    end
  end
end
