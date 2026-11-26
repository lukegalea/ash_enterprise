defmodule AshBrowserTests.ReportTest do
  @moduledoc """
  The report is the only thing a reviewer looks at, so the parts worth asserting
  are the ones that would quietly mislead: a file matched to the wrong test, a
  failure sorted below thirty passes, media counted as absent, or a summary that
  stops early without saying so.
  """

  use ExUnit.Case, async: true

  alias AshBrowserTests.Report

  defp row(attrs) do
    Enum.into(attrs, %{key: "M.t", screenshots: [], status: "passed", traces: []})
  end

  describe "key_of/2" do
    test "a screenshot loses its timestamp" do
      assert Report.key_of("tmp/shots/My.AppTest.test_signs_in_1763404800.png", ".png") ==
               "My.AppTest.test_signs_in"
    end

    test "a trace loses its timestamp and its unique integer" do
      assert Report.key_of("tmp/traces/My.AppTest.test_signs_in_1763404800_15.zip", ".zip") ==
               "My.AppTest.test_signs_in"
    end

    test "a screenshot and a trace for one test agree on the key" do
      # The whole join rests on this. They are named by different code paths in
      # the driver, with a different number of numeric suffixes.
      shot = Report.key_of("a/My.AppTest.test_x_1763404800.png", ".png")
      trace = Report.key_of("b/My.AppTest.test_x_1763404800_7.zip", ".zip")

      assert shot == trace
    end

    test "a test name ending in a digit keeps it" do
      # Greedy stripping of every trailing `_<digits>` would turn `test_retry_2`
      # into `test_retry`, quietly merging two tests into one row.
      assert Report.key_of("My.AppTest.test_retry_2_1763404800.png", ".png") ==
               "My.AppTest.test_retry_2"

      assert Report.key_of("My.AppTest.test_retry_2_1763404800_3.zip", ".zip") ==
               "My.AppTest.test_retry_2"
    end

    test "a name with no timestamp is returned as it is, rather than mangled" do
      assert Report.key_of("whatever.png", ".png") == "whatever"
    end
  end

  describe "order/1" do
    test "failures come first, whatever they are called" do
      rows = [
        row(key: "AAA", status: "passed"),
        row(key: "zzz", status: "failed"),
        row(key: "mmm", status: "unknown")
      ]

      assert rows |> Enum.sort_by(&Report.order/1) |> Enum.map(& &1.key) == ["zzz", "mmm", "AAA"]
    end

    test "an unknown status sorts above a pass, because it means no result was recorded" do
      assert Report.order(row(status: "unknown")) < Report.order(row(status: "passed"))
    end
  end

  describe "html/3" do
    test "links media relatively to the page, so an unzipped artifact works" do
      html =
        [row(key: "M.t", screenshots: ["tmp/playwright/screenshots/M.t_1.png"])]
        |> Report.html("Run", "tmp/playwright")
        |> IO.iodata_to_binary()

      assert html =~ ~s(src="screenshots/M.t_1.png")
      refute html =~ "tmp/playwright/screenshots"
    end

    test "is self-contained: no external request of any kind" do
      html =
        [row(screenshots: ["a/b_1.png"])]
        |> Report.html("Run", "a")
        |> IO.iodata_to_binary()

      refute html =~ "http://"
      refute html =~ "https://"
      refute html =~ "<script"
    end

    test "says so when a test left no screenshot" do
      html = [row([])] |> Report.html("Run", ".") |> IO.iodata_to_binary()

      assert html =~ "no screenshot"
    end

    test "shows the failure message, escaped" do
      html =
        [row(status: "failed", failure: ~s(expected <b>"a"</b> to match))]
        |> Report.html("Run", ".")
        |> IO.iodata_to_binary()

      assert html =~ "&lt;b&gt;"
      refute html =~ "<b>"
    end

    test "a test name containing markup cannot break out of the page" do
      html =
        [row(name: ~s(test <img onerror="x"> injected))]
        |> Report.html("Run", ".")
        |> IO.iodata_to_binary()

      refute html =~ "<img onerror"
      assert html =~ "&lt;img onerror"
    end

    test "counts every status in the header" do
      html =
        [row(key: "a", status: "passed"), row(key: "b", status: "failed")]
        |> Report.html("Run", ".")
        |> IO.iodata_to_binary()

      assert html =~ "1 failed"
      assert html =~ "1 passed"
    end

    test "names the newest of several attempts and counts the rest" do
      html =
        [
          row(
            screenshots: ["s/M.t_2.png", "s/M.t_1.png"],
            traces: ["t/M.t_2_1.zip", "t/M.t_1_1.zip"]
          )
        ]
        |> Report.html("Run", ".")
        |> IO.iodata_to_binary()

      assert html =~ "s/M.t_2.png"
      assert html =~ "earlier attempt"
    end
  end

  describe "markdown/2" do
    test "a failure is in the table and its message is in the details" do
      md =
        [row(name: "test signs in", status: "failed", failure: "boom")]
        |> Report.markdown("Run")
        |> IO.iodata_to_binary()

      assert md =~ "test signs in"
      assert md =~ "✗"
      assert md =~ "<details><summary>Failures</summary>"
      assert md =~ "boom"
    end

    test "no failures means no details block" do
      md = [row([])] |> Report.markdown("Run") |> IO.iodata_to_binary()

      refute md =~ "<details>"
    end

    test "a pipe in a test name cannot break the table" do
      md =
        [row(name: "test a|b")]
        |> Report.markdown("Run")
        |> IO.iodata_to_binary()

      assert md =~ "test a\\|b"
    end

    test "says how many rows it left out rather than stopping silently" do
      rows = for n <- 1..200, do: row(key: "t#{String.pad_leading("#{n}", 4, "0")}")

      md = rows |> Report.markdown("Run") |> IO.iodata_to_binary()

      assert md =~ "50 more not shown"
    end

    test "reports media presence per test" do
      md =
        [
          row(key: "a", screenshots: ["a_1.png"]),
          row(key: "b", traces: ["b_1_1.zip"]),
          row(key: "c")
        ]
        |> Report.markdown("Run")
        |> IO.iodata_to_binary()

      assert md =~ "shot"
      assert md =~ "trace"
    end
  end

  describe "journeys" do
    defp journey_row(key, id, locale, status \\ "passed") do
      row(key: key, name: key, status: status, journey: %{id: id, locale: locale})
    end

    test "groups a journey's locales together, journeys before other tests" do
      rows = [
        row(key: "plain", name: "plain", status: "failed"),
        journey_row("b-en", "b", "en"),
        journey_row("a-en", "a", "en", "failed"),
        journey_row("b-fr", "b", "fr")
      ]

      assert [{"b", [%{key: "b-en"}, %{key: "b-fr"}]}, {"a", [_]}, {nil, [%{key: "plain"}]}] =
               Report.groups(rows)

      html = rows |> Report.html("Run", ".") |> IO.iodata_to_binary()
      assert html =~ "<h2>Journey b</h2>"
      assert html =~ "<h2>Other tests</h2>"

      md = rows |> Report.markdown("Run") |> IO.iodata_to_binary()
      assert md =~ "### Journey `a`"
      assert md =~ "### Other tests"
    end

    test "a run with no journeys keeps one plain table" do
      md = [row(key: "x", name: "x")] |> Report.markdown("Run") |> IO.iodata_to_binary()
      refute md =~ "###"
      assert md =~ "| | Test | Time | Media |"
    end
  end
end
