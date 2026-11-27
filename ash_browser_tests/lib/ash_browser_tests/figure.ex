defmodule AshBrowserTests.Figure do
  @moduledoc """
  A screenshot taken where a test says, of a settled page, under a framing that
  makes two runs of the same state agree pixel for pixel.

      {conn, figure} = Figure.capture(conn, "tmp/run/02-find.people.png",
        selector: ~s([data-a2ui-id="data_grid"]),
        mask: [{"#as-of", "6rem"}])

  The driver's own screenshot (`screenshot: true`) is one per test, taken at
  exit and named with a timestamp; a figure is taken at a point of the test, to
  the path the test names.

  Every capture first waits for `AshBrowserTests.Settle` (a page that does not
  settle fails the capture), then goes through Playwright's screenshot
  expectation in capture-only mode (no baseline): it waits until two
  consecutive captures agree, with CSS animations and transitions stopped and
  the caret hidden, so a figure is not taken halfway through a transition.

  `:selector` crops to one element. Playwright's CSS engine pierces open shadow
  roots, so a selector such as `[data-a2ui-row-id="…"]` reaches a row a grid
  draws inside its own shadow root, with no `evaluate`.
  """

  alias AshBrowserTests.Settle
  alias PhoenixTest.Playwright.Config
  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page

  # Applied by Playwright for the capture only, through shadow roots and into
  # frames: no caret, no transition or animation mid-flight, no smooth scroll.
  @freeze_css """
  *, *::before, *::after {
    caret-color: transparent !important;
    transition: none !important;
    animation: none !important;
    scroll-behavior: auto !important;
  }
  """

  @type t :: %{
          path: String.t(),
          png: binary(),
          sha256: String.t(),
          settled: Settle.state()
        }

  @type box :: %{x: number(), y: number(), width: number(), height: number()}

  @doc "The CSS every capture applies (see `capture/3`)."
  @spec freeze_css() :: String.t()
  def freeze_css, do: @freeze_css

  @doc """
  The browser-context options a figure is shot under, for
  `browser_context_opts`: a fixed viewport and device scale factor, reduced
  motion, a fixed colour scheme, locale and time zone. Every figure of a
  journey is shot under one framing, or two runs cannot agree.
  """
  @spec framing(keyword()) :: keyword()
  def framing(overrides \\ []) do
    Keyword.merge(
      [
        viewport: %{width: 1280, height: 800},
        device_scale_factor: 1.0,
        reduced_motion: "reduce",
        color_scheme: :light,
        locale: "en-US",
        timezone_id: "UTC"
      ],
      overrides
    )
  end

  @doc """
  Waits for the page to settle, captures it (or, with `:selector`, one element)
  to `path`, and returns `{conn, figure}`: the file's path and bytes, their
  SHA-256 as lowercase hex, and the settled state the capture was taken in.

  Options:

    * `:selector` - a Playwright selector to crop to. It must resolve to one
      element; add `>> visible=true` where a page draws an element twice.
    * `:mask` - regions painted over, each a selector or `{selector, width}`.
      A width fixes the element's width (a CSS length) for the capture, so
      text of another length under the mask cannot move the layout around it.
    * `:scale` - `"css"` (default) or `"device"`.
    * `:timeout` - the capture's, default the configured Playwright timeout.
    * `:settle` - options for `AshBrowserTests.Settle.wait!/2`.
  """
  @spec capture(struct(), Path.t(), keyword()) :: {struct(), t()}
  def capture(conn, path, opts \\ []) do
    %{page_id: page_id, frame_id: frame_id} = Settle.ids(conn)
    {conn, settled} = Settle.wait!(conn, Keyword.get(opts, :settle, []))
    masks = Enum.map(Keyword.get(opts, :mask, []), &mask/1)

    params =
      [
        timeout: Keyword.get_lazy(opts, :timeout, fn -> Config.global(:timeout) end),
        animations: "disabled",
        caret: "hide",
        scale: Keyword.get(opts, :scale, "css"),
        style: [@freeze_css | Enum.map(masks, &width_css/1)] |> Enum.join("\n")
      ]
      |> put_if(:locator, locator(Keyword.get(opts, :selector), frame_id))
      |> put_if(:mask, masks != [] && Enum.map(masks, &locator(elem(&1, 0), frame_id)))

    case Page.expect_screenshot(page_id, params) do
      {:ok, base64} when is_binary(base64) ->
        png = Base.decode64!(base64)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, png)
        {conn, %{path: path, png: png, sha256: sha256(png), settled: settled}}

      other ->
        raise ExUnit.AssertionError,
          message: "figure #{path} could not be captured: #{inspect(other, limit: 5)}"
    end
  end

  @doc """
  The box of the one element `selector` resolves to, in CSS pixels relative to
  the viewport, as it is now. Raises when the element is not there.
  """
  @spec box(struct(), String.t()) :: box()
  def box(conn, selector) do
    frame_id = Settle.ids(conn).frame_id

    with {:ok, %{guid: element}} <-
           Frame.wait_for_selector(frame_id, selector: selector, timeout: 5_000),
         {:ok, box} <-
           ElementHandle.evaluate(element,
             expression:
               "(el) => { const r = el.getBoundingClientRect(); " <>
                 "return {x: r.x, y: r.y, width: r.width, height: r.height} }",
             is_function: true,
             timeout: 5_000
           ) do
      box = Map.new(box, fn {key, value} -> {to_string(key), value} end)
      %{x: box["x"], y: box["y"], width: box["width"], height: box["height"]}
    else
      other ->
        raise ExUnit.AssertionError,
          message: "no box for #{inspect(selector)}: #{inspect(other, limit: 5)}"
    end
  end

  defp mask({selector, width}), do: {selector, width}
  defp mask(selector) when is_binary(selector), do: {selector, nil}

  defp width_css({_selector, nil}), do: ""

  defp width_css({selector, width}) do
    "#{selector} { display: inline-block !important; box-sizing: border-box !important; " <>
      "width: #{width} !important; min-width: #{width} !important; " <>
      "max-width: #{width} !important; overflow: hidden !important; " <>
      "white-space: nowrap !important; vertical-align: bottom !important; }"
  end

  defp locator(nil, _frame_id), do: nil
  defp locator(selector, frame_id), do: %{frame: %{guid: frame_id}, selector: selector}

  defp put_if(params, _key, value) when value in [nil, false], do: params
  defp put_if(params, key, value), do: Keyword.put(params, key, value)

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
