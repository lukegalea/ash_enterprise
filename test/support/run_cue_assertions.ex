defmodule AshEnterpriseWeb.RunCueAssertions do
  @moduledoc """
  Assertions for the test-versus-live cue (`AshEnterpriseWeb.StatusComponents.run_mode/1`)
  on any surface that shows a run.

      import AshEnterpriseWeb.RunCueAssertions

      assert_test_cue(view, "#shadow-rows")
      refute_live_claim(view, "#candidate")

  Each takes a LiveView (`Phoenix.LiveViewTest.View`), a rendered HTML string or a
  `LazyHTML` tree, and a CSS selector naming where the run is shown.
  """

  import ExUnit.Assertions

  @doc """
  Every cue under `selector` says test, at least one is there, and none says live
  or unknown. Returns the run modes the cues name.
  """
  @spec assert_test_cue(term(), String.t()) :: [String.t()]
  def assert_test_cue(rendered, selector) do
    cues = cues(rendered, selector)
    assert cues != [], "no run cue under #{selector}"

    for {environment, mode, text} <- cues do
      assert environment == "test",
             "a cue under #{selector} says #{inspect(environment)}, not test: #{text}"

      assert text =~ "Test run", "a test cue under #{selector} reads #{inspect(text)}"
      refute text =~ ~r/\blive run\b/i
      mode
    end
  end

  @doc """
  Nothing under `selector` claims a live run: no cue says live, and no text reads
  "Live run". A missing or unknown mode reads as unknown.
  """
  @spec refute_live_claim(term(), String.t()) :: :ok
  def refute_live_claim(rendered, selector) do
    tree = tree(rendered)

    for {environment, _mode, text} <- cues(tree, selector) do
      refute environment == "live", "a cue under #{selector} claims a live run: #{text}"
    end

    refute tree |> LazyHTML.query(selector) |> LazyHTML.text() =~ ~r/\blive run\b/i,
           "the text under #{selector} claims a live run"

    :ok
  end

  defp cues(rendered, selector) do
    tree(rendered)
    |> LazyHTML.query(selector)
    |> LazyHTML.query("[data-run-environment]")
    |> Enum.map(fn cue ->
      {attribute(cue, "data-run-environment"), attribute(cue, "data-run-mode"),
       cue |> LazyHTML.text() |> String.trim()}
    end)
  end

  defp attribute(node, name) do
    case LazyHTML.attribute(node, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp tree(%LazyHTML{} = tree), do: tree
  defp tree(html) when is_binary(html), do: LazyHTML.from_fragment(html)
  defp tree(view), do: view |> Phoenix.LiveViewTest.render() |> LazyHTML.from_fragment()
end
