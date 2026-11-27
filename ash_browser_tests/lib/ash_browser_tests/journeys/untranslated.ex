if Code.ensure_loaded?(AshJourneys.Run) do
  defmodule AshBrowserTests.Journeys.Untranslated do
    @moduledoc """
    The text a journey's figure shows that never went through translation, found
    in a run in the host's pseudo-locale (`AshBrowserTests.Journeys`).

    In the pseudo-locale every message the host translates comes back as its msgid
    with every ASCII letter accented. So a word of two or more ASCII letters in
    the text a figured region shows was not translated, unless it is data
    (`c:AshBrowserTests.Journeys.Host.visible_data/1`). What a figure masks is not
    read.
    """

    alias AshBrowserTests.Settle
    alias PlaywrightEx.ElementHandle
    alias PlaywrightEx.Frame

    @word ~r/[A-Za-z]{2,}/

    # The text of every visible text node under the root, and every visible
    # placeholder, through open shadow roots, except what sits in an element that
    # matches one of the masks.
    @collect """
    (root, masks) => {
      const texts = [];
      const shown = (el) => {
        if (!el) return false;
        const box = el.getBoundingClientRect();
        const style = getComputedStyle(el);
        return box.width > 0 && box.height > 0 && style.visibility !== "hidden" && style.display !== "none";
      };
      const skipped = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE"]);
      const walk = (node) => {
        if (node.nodeType === Node.TEXT_NODE) {
          const text = node.textContent.trim();
          if (text && shown(node.parentElement)) texts.push(text);
          return;
        }
        if (node.nodeType === Node.ELEMENT_NODE) {
          if (skipped.has(node.tagName) || masks.some((mask) => node.matches(mask))) return;
          if (node.placeholder && shown(node)) texts.push(node.placeholder);
          if (node.shadowRoot) walk(node.shadowRoot);
        }
        node.childNodes.forEach(walk);
      };
      walk(root);
      return texts;
    }
    """

    @doc """
    The visible text under `selector` (the page's body when `nil`) of the page
    `conn` is on, outside the elements matching the CSS selectors in `masks`.
    """
    @spec texts(struct(), String.t() | nil, [String.t()]) :: [String.t()]
    def texts(conn, selector, masks) do
      frame_id = Settle.ids(conn).frame_id

      with {:ok, %{guid: root}} <-
             Frame.wait_for_selector(frame_id, selector: selector || "body", timeout: 5_000),
           {:ok, texts} <-
             ElementHandle.evaluate(root,
               expression: @collect,
               arg: masks,
               is_function: true,
               timeout: 5_000
             ) do
        texts
      else
        other ->
          raise ExUnit.AssertionError,
            message: "no text to read under #{inspect(selector)}: #{inspect(other, limit: 5)}"
      end
    end

    @doc """
    The texts with a word of ASCII letters left once every string in `data` is
    taken out of them.
    """
    @spec english([String.t()], [String.t()]) :: [String.t()]
    def english(texts, data) do
      data = Enum.sort_by(data, &(-String.length(&1)))

      Enum.filter(texts, fn text ->
        Regex.match?(@word, Enum.reduce(data, text, &String.replace(&2, &1, "")))
      end)
    end

    @doc """
    Raises, naming `where`, when a visible text under `selector` is English.
    """
    @spec assert_translated!(struct(), String.t() | nil, [String.t()], [String.t()], String.t()) ::
            :ok
    def assert_translated!(conn, selector, masks, data, where) do
      case conn |> texts(selector, masks) |> english(data) do
        [] ->
          :ok

        found ->
          raise ExUnit.AssertionError,
            message:
              "visible English in the pseudo-locale, on #{where}:\n" <>
                Enum.map_join(found, "\n", &"  #{inspect(&1)}")
      end
    end
  end
end
