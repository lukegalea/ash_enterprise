defmodule AshBrowserTests.Settle do
  @moduledoc """
  Whether a page has finished what it was doing, so a screenshot or an
  expectation sees an outcome and not the moment before it.

  Playwright's screenshot expectation waits for two identical consecutive
  frames. That is not enough on its own: a pending state can hold still for
  longer than two frames. An A2UI action writes `/ui/feedback =
  %{kind: "pending"}` the moment it is clicked, and its row-action button is
  disabled and busy until the answer lands, a round trip later; with
  animations stopped, that "Working…" frame is perfectly stable.

  The page is settled when every one of these holds for `:frames`
  consecutive animation frames:

    * the document has loaded and `document.fonts` is `"loaded"`;
    * every LiveView root (`[data-phx-session]`) is `phx-connected`, and no
      element carries a `phx-*-loading` class (an event not yet acknowledged);
    * no A2UI surface is still showing its bootstrap skeleton
      (`[data-ash-a2ui-skeleton]`), and no A2UI hook container carries
      `data-a2ui-pending` (a call sent and not yet answered);
    * no A2UI surface's data model has `/ui/feedback/kind == "pending"` (an
      outcome-bearing action not yet answered, including the slow `TIMEOUT`
      notice) or `/ui/loading == true` (a query or report fetch in flight).
      The model is read through each `<a2ui-surface>` element's
      `surface.dataModel`, which the AshA2ui hook binds; an `ash_a2ui` that
      sets `data-a2ui-pending` makes this read redundant, one that does not
      needs it;
    * nothing in the composed tree, shadow roots included, is
      `aria-busy="true"` (busy buttons, the skeleton);
    * nothing carries `data-a2ui-flashed` (a document's three-second flash on
      the value it just scrolled to);
    * every `<img>` has finished loading.

  `data-a2ui-live` is not a settle signal: it marks a link the surface
  declared live (a LiveView navigation), whatever the page is doing.
  """

  alias PhoenixTest.Playwright
  alias PlaywrightEx.Frame

  @probe """
  () => {
    const all = []
    const walk = (root) => {
      for (const el of root.querySelectorAll("*")) {
        all.push(el)
        if (el.shadowRoot) walk(el.shadowRoot)
      }
    }
    walk(document)
    const loadingClasses = [
      "phx-click-loading", "phx-submit-loading", "phx-change-loading",
      "phx-keyup-loading", "phx-keydown-loading", "phx-focus-loading",
      "phx-blur-loading", "phx-hook-loading"
    ]
    const views = [...document.querySelectorAll("[data-phx-session]")]
    const surfaces = all
      .filter((el) => el.localName === "a2ui-surface" && el.surface && el.surface.dataModel)
      .map((el) => {
        const get = (path) => {
          try { return el.surface.dataModel.get(path) } catch (_e) { return undefined }
        }
        return {
          feedback: get("/ui/feedback/kind") ?? null,
          loading: get("/ui/loading") === true
        }
      })
    const state = {
      ready: document.readyState,
      fonts: document.fonts ? document.fonts.status : "loaded",
      views: views.length,
      unconnected: views.filter((el) => !el.classList.contains("phx-connected")).length,
      lv_loading: all.filter((el) => loadingClasses.some((c) => el.classList.contains(c))).length,
      skeleton: all.filter((el) => el.hasAttribute("data-ash-a2ui-skeleton")).length,
      pending_marks: all.filter((el) => el.hasAttribute("data-a2ui-pending")).length,
      surfaces: surfaces.length,
      pending: surfaces.filter((s) => s.feedback === "pending").length,
      loading: surfaces.filter((s) => s.loading).length,
      busy: all.filter((el) => el.getAttribute("aria-busy") === "true").length,
      flashed: all.filter((el) => el.hasAttribute("data-a2ui-flashed")).length,
      images: [...document.images].filter((img) => !img.complete).length,
      feedback: surfaces.map((s) => s.feedback)
    }
    state.settled =
      state.ready === "complete" && state.fonts === "loaded" && state.unconnected === 0 &&
      state.lv_loading === 0 && state.skeleton === 0 && state.pending_marks === 0 &&
      state.pending === 0 && state.loading === 0 && state.busy === 0 &&
      state.flashed === 0 && state.images === 0
    return state
  }
  """

  # The predicate `wait_for_function` polls once per animation frame: settled
  # for `frames` frames in a row, counted under a token so two waits never
  # share a count.
  @wait """
  ({token, frames}) => {
    const probe = (#{@probe})
    const state = probe()
    const mark = window.__ashBrowserTestsSettle
    const count = state.settled ? (mark && mark.token === token ? mark.count + 1 : 1) : 0
    window.__ashBrowserTestsSettle = {token, count}
    return count >= frames ? state : false
  }
  """

  @type state :: %{optional(String.t()) => term()}

  @doc "The page's state now, as the settle wait reads it (`\"settled\"` among it)."
  @spec probe(struct()) :: state()
  def probe(conn) do
    case Frame.evaluate(frame_id(conn), expression: @probe, is_function: true, timeout: 5_000) do
      {:ok, state} ->
        stringify(state)

      {:error, error} ->
        raise ExUnit.AssertionError, message: "settle probe failed: #{inspect(error)}"
    end
  end

  @doc """
  Waits until the page is settled and returns `{conn, state}`, the state read
  once it was. Raises with the last state read when it does not settle: a page
  that never settles is a failure to report, never one to shoot anyway.

  Options: `:timeout` (ms, default 15 000), `:frames` (consecutive settled
  frames, default 3).
  """
  @spec wait!(struct(), keyword()) :: {struct(), state()}
  def wait!(conn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    frames = Keyword.get(opts, :frames, 3)
    token = Integer.to_string(System.unique_integer([:positive]))

    case Frame.wait_for_function(frame_id(conn),
           expression: @wait,
           is_function: true,
           arg: %{token: token, frames: frames},
           polling: "raf",
           timeout: timeout
         ) do
      {:ok, _handle} ->
        {conn, probe(conn)}

      {:error, error} ->
        raise ExUnit.AssertionError,
          message:
            "the page did not settle within #{timeout}ms; last state: " <>
              inspect(safe_probe(conn)) <> "\n" <> inspect(error, limit: 3)
    end
  end

  defp safe_probe(conn) do
    probe(conn)
  rescue
    _error -> :unavailable
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  @doc false
  # The Playwright ids behind a session.
  @spec ids(struct()) :: %{page_id: String.t(), frame_id: String.t()}
  def ids(conn) do
    parent = self()
    ref = make_ref()
    Playwright.unwrap(conn, &send(parent, {ref, &1}))

    receive do
      {^ref, ids} -> ids
    end
  end

  defp frame_id(conn), do: ids(conn).frame_id
end
