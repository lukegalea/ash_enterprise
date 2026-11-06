defmodule AshEnterpriseWeb.StatusComponentsTest do
  @moduledoc """
  The shared status message and the test-versus-live run cue
  (`AshEnterpriseWeb.StatusComponents`), and the rule that pages announce news only
  through them.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest
  import AshEnterpriseWeb.RunCueAssertions

  alias AshEnterpriseWeb.StatusComponents

  doctest AshEnterpriseWeb.StatusComponents

  defp status(assigns) do
    ~H"""
    <StatusComponents.status_message id="note" role={@role} show={@show} kind={:warning}>
      Saved.
    </StatusComponents.status_message>
    """
  end

  defp cue(mode), do: render_component(&StatusComponents.run_mode/1, mode: mode, id: "cue")

  defp one(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  describe "status_message/1" do
    test "the region is on the page with or without a message, so arrivals are announced" do
      shown = render_component(&status/1, role: "status", show: true)
      hidden = render_component(&status/1, role: "status", show: false)

      assert [_] = one(shown, "#note-region[role=status] #note") |> Enum.to_list()
      assert shown =~ "Saved."

      # Nothing to say: the region stays, the message does not, and the empty region
      # takes no space while staying in the accessibility tree.
      assert [region] = one(hidden, "#note-region[role=status]") |> Enum.to_list()
      assert LazyHTML.attribute(region, "class") == ["sr-only"]
      assert one(hidden, "#note") |> Enum.to_list() == []
      refute hidden =~ "Saved."
    end

    test "takes the WAI-ARIA role it is given, and sets no live attributes of its own" do
      for role <- ~w(status alert log) do
        html = render_component(&status/1, role: role, show: true)
        assert [_] = one(html, "#note-region[role=#{role}]") |> Enum.to_list()
        refute html =~ "aria-live"
        refute html =~ "autofocus"
      end
    end
  end

  describe "run_environment/1" do
    test "live is only :live" do
      assert StatusComponents.run_environment(:live) == :live
      assert StatusComponents.run_environment("live") == :live
    end

    test "eval, shadow, adhoc and a suite run's offline are tests" do
      for mode <- [:eval, :shadow, :adhoc, :offline, "eval", "shadow", "adhoc", "offline"] do
        assert StatusComponents.run_environment(mode) == :test, inspect(mode)
      end
    end

    test "a missing, unknown or malformed mode is unknown, never live" do
      for mode <- [nil, "", :unknown, :LIVE, "Live", "LIVE", " live", :errored, 1, %{}, {:live}] do
        assert StatusComponents.run_environment(mode) == :unknown, inspect(mode)
      end
    end
  end

  describe "run_mode/1" do
    test "a test run carries a visible test cue naming the kind of test" do
      for {mode, kind} <- [
            eval: "evaluation",
            shadow: "shadow",
            adhoc: "experiment",
            offline: "evaluation"
          ] do
        html = cue(mode)
        assert [mode_name] = assert_test_cue(html, "#cue")
        assert mode_name == to_string(mode)
        assert html =~ kind
        refute_live_claim(html, "#cue")
      end
    end

    test "a live run says so" do
      html = cue(:live)

      assert [_] =
               one(html, "#cue[data-run-environment=live][data-run-mode=live]") |> Enum.to_list()

      assert html =~ "Live run"
    end

    test "a missing or unknown mode makes no live claim and no test claim" do
      for mode <- [nil, "", :errored, "LIVE", %{}] do
        html = cue(mode)

        assert [cue] = one(html, "#cue[data-run-environment=unknown]") |> Enum.to_list()
        assert LazyHTML.attribute(cue, "data-run-mode") == []
        assert html =~ "Run mode unknown"
        refute_live_claim(html, "#cue")
        refute html =~ "Test run"
      end
    end

    test "the assertions fail on a live cue or on no cue at all" do
      assert_raise ExUnit.AssertionError, fn -> assert_test_cue(cue(:live), "#cue") end
      assert_raise ExUnit.AssertionError, fn -> assert_test_cue(cue(nil), "#cue") end

      assert_raise ExUnit.AssertionError, fn ->
        assert_test_cue("<p id=cue>Test run</p>", "#cue")
      end

      assert_raise ExUnit.AssertionError, fn -> refute_live_claim(cue(:live), "#cue") end
    end
  end

  # A live region a page writes by hand is easy to get wrong (inserted with its
  # message, it is often not announced), so pages announce through the shared
  # component. The flash, Phoenix's own, keeps its region in Layouts.
  @own ~w(
    lib/ash_enterprise_web/components/status_components.ex
    lib/ash_enterprise_web/components/core_components.ex
    lib/ash_enterprise_web/components/layouts.ex
  )

  test "no page writes its own live region" do
    hand_written =
      for path <- Path.wildcard("lib/ash_enterprise_web/**/*.{ex,heex}"),
          path not in @own,
          source = File.read!(path),
          [tag, name] <-
            Regex.scan(
              ~r/<([\w.]+)(?:[^>]|->)*?(?:\brole="(?:status|alert|log)"|aria-live=)/s,
              source
            ),
          name not in [".live_region", ".status_message"],
          do: "#{path}: #{tag |> String.split("\n") |> hd()}"

    assert hand_written == []
  end
end
