defmodule AshEnterpriseWeb.E2E.GuideTest do
  @moduledoc """
  The in-app guide (`AshEnterpriseWeb.GuideLive`) as a member with no grants sees
  it: opened from the shell's `/guide <journey>`, it shows the approved run's
  numbered steps and loaded figures that fit the page, in English and French, on a
  desktop and at phone width. A message the browser cannot apply shows an error,
  never a blank surface.

  Assertions are on content (text, a decoded image), never on the surface element
  being present: an `a2ui-surface` that applied nothing is still there.
  """

  use AshBrowserTests.Case, async: true

  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterpriseWeb.E2E.Login

  @path "/app/guide/revoke_a_leavers_access"

  defp member do
    admin = DailyFixtures.tenant!()
    DailyFixtures.member!(admin, "Reader", [])
  end

  defp open_guide(conn, line \\ "/guide revoke_a_leavers_access") do
    conn
    |> Login.as(member())
    |> visit("/app")
    |> assert_connected()
    |> press("body", "Control+p")
    |> assert_has("#a2ui-shell-form")
    |> type("#a2ui-shell-form input", line)
    |> press("#a2ui-shell-form input", "Enter")
    |> assert_path(@path)
    |> assert_connected()
  end

  # What the page shows: the ordered lists' numbering, each image's state and size,
  # and whether the page scrolls sideways.
  defp layout(conn) do
    eval_js(conn, """
    (() => {
      #{AshBrowserTests.Browser.walker()}
      const lists = deep(document, "ol").map((ol) => ({
        start: ol.start,
        style: getComputedStyle(ol).listStyleType,
        item: ol.querySelector("li") && getComputedStyle(ol.querySelector("li")).display
      }))
      const images = deep(document, "img").filter((img) => img.src.includes("/app/guide/figures/")).map((img) => ({
        loaded: img.complete && img.naturalWidth > 0,
        natural: img.naturalWidth,
        column: (img.getRootNode().host || img.parentElement).getBoundingClientRect().width,
        width: img.getBoundingClientRect().width,
        height: img.getBoundingClientRect().height
      }))
      return {lists, images, page: document.documentElement.clientWidth, scroll: document.documentElement.scrollWidth}
    })()
    """)
  end

  defp eval_js(conn, expression) do
    parent = self()
    ref = make_ref()
    PhoenixTest.Playwright.evaluate(conn, expression, &send(parent, {ref, &1}))

    receive do
      {^ref, value} -> value
    after
      5_000 -> flunk("the page did not answer evaluate")
    end
  end

  defp assert_guide(conn, texts) do
    conn = assert_deep(conn, "li", text: hd(texts), timeout: 15_000)
    for text <- texts, do: assert_deep(conn, "a2ui-surface *", text: text)

    # Every figure decodes and is drawn, inside the page.
    deadline = System.monotonic_time(:millisecond) + 10_000
    layout = wait_for_images(conn, deadline)

    assert length(layout["images"]) == 4
    for image <- layout["images"], do: assert(image["loaded"] and image["width"] > 0)
    for image <- layout["images"], do: assert(image["width"] <= layout["page"])
    assert layout["scroll"] <= layout["page"]

    # Each is drawn at its own size, scaled down only to fit the column.
    for image <- layout["images"],
        do: assert_in_delta(image["width"], min(image["natural"], image["column"]), 1)

    # The steps keep their numbers, and the numbers are drawn.
    assert Enum.map(layout["lists"], & &1["start"]) == [1, 2, 3, 4]
    for list <- layout["lists"], do: assert(list["style"] == "decimal")

    {conn, layout}
  end

  defp wait_for_images(conn, deadline) do
    layout = layout(conn)

    cond do
      layout["images"] != [] and Enum.all?(layout["images"], & &1["loaded"]) ->
        layout

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(100)
        wait_for_images(conn, deadline)

      true ->
        flunk("the guide's figures did not load: #{inspect(layout)}")
    end
  end

  test "the shell opens the guide: its numbered steps and loaded figures", %{conn: conn} do
    {_conn, layout} =
      conn
      |> open_guide()
      |> assert_guide([
        "The person who is leaving is still signed in",
        "Open Users and find the person who is leaving.",
        "Choose Deactivate on their row, and confirm.",
        "The next thing they do in the app sends them to sign in.",
        "Their account is inactive"
      ])

    # On a desktop a cropped figure keeps its size: one is narrower than the column.
    assert Enum.any?(layout["images"], &(&1["natural"] < &1["column"]))
  end

  @tag browser_context_opts: [locale: "fr-FR"]
  test "in French", %{conn: conn} do
    conn
    |> open_guide()
    |> assert_deep("#page-header", text: "Révoquer l'accès")
    |> assert_guide([
      "La personne qui s'en va est toujours connectée",
      "Ouvrez Utilisateurs et trouvez la personne qui s'en va.",
      "Choisissez Désactiver sur sa ligne, puis confirmez."
    ])
  end

  @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
  test "at phone width, the figures fit the page", %{conn: conn} do
    conn
    |> Login.as(member())
    |> visit(@path)
    |> assert_connected()
    |> assert_guide(["Open Users and find the person who is leaving."])
    |> then(fn {_conn, layout} ->
      # The full-page captures are scaled down to the phone's column.
      assert Enum.any?(layout["images"], &(&1["width"] < &1["natural"]))
      assert layout["page"] == 390
    end)
  end

  test "a message the browser cannot apply shows an error, not a blank surface", %{conn: conn} do
    conn =
      conn
      |> Login.as(member())
      |> visit(@path)
      |> assert_connected()
      |> assert_deep("li", text: "Open Users", timeout: 15_000)

    # The guide's own surface, with the version the browser refuses.
    eval_js(conn, """
    (() => {
      const message = {version: "v1.0", createSurface: {surfaceId: "guide-revoke_a_leavers_access-bad",
        catalogId: "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json",
        components: [{id: "root", component: "Text", text: "never shown"}]}}
      window.dispatchEvent(new CustomEvent("phx:a2ui:messages", {detail: {messages: [message]}}))
      return true
    })()
    """)

    conn
    |> assert_deep("[data-a2ui-error][role=alert]", text: "version")
    |> refute_deep("a2ui-surface *", text: "never shown")

    take_browser_failures(conn, ~r/version|VALIDATION/i)
  end
end
