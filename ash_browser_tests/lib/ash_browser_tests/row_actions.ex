defmodule AshBrowserTests.RowActions do
  @moduledoc """
  Driving one A2UI row action, from the manifest: click it in its row (the
  control's accessible name is the manifest's `label`), fill or select its
  `prompt_fields` by their labels (by widget), and confirm through the
  prompt's `confirm_label`.

  Locators use roles, accessible names, and the `data-a2ui-*` attributes the
  manifest lists (`selector`, row ids) — nothing else — so driving a surface
  also exercises its accessibility. Nothing in here knows a host.

  The row is the element carrying the record's id (`data-a2ui-row-id`):
  ash_a2ui marks every record row and card with it, so no row is found by
  its text. The row's `text` appears only in failure messages.
  """

  alias AshBrowserTests.Browser
  alias AshBrowserTests.Trace

  # A control's accessible name: its `aria-label`, else its text collected
  # through shadow roots. An Atlas button draws its label in its own shadow
  # root, so `textContent` (light DOM only) sees nothing.
  @deep_text_js """
  function deepText(node) {
    let out = ""
    const walk = (node) => {
      if (node.nodeType === 3) {
        out += node.textContent
      } else if (node.nodeType === 1) {
        if (node.shadowRoot) {
          for (const child of node.shadowRoot.childNodes) walk(child)
        }
        for (const child of node.childNodes) walk(child)
      }
    }
    walk(node)
    return out
  }
  """

  # --- The span chain ------------------------------------------------------------

  @doc """
  The chain a row action asserts: the browser event span under the server's
  `handle_event`, under which the Ash action runs.
  """
  @spec chain(map()) :: [AshBrowserTests.Span.matcher()]
  def chain(row_action) do
    [
      Trace.browser_event(),
      Trace.handle_event(),
      ash_action_span(row_action.ash_action)
    ]
  end

  # The action's span carries `ash.action`, the invoked action's name —
  # except on the engine's generic work actions: `HumanTask.claim_task`
  # runs `WorkTask, op: :claim` and the span's attribute is `claim`. The
  # span's *name* always ends with the manifest's action name, so the
  # matcher takes either.
  defp ash_action_span(action) do
    expected = to_string(action)

    fn span ->
      to_string(span.attributes["ash.action"]) == expected or
        String.ends_with?(span.name, "." <> expected)
    end
  end

  # --- Driving -------------------------------------------------------------------

  @doc """
  Clicks `row_action` in the row for `row` (by its `data-a2ui-row-id`), fills its prompt fields from `inputs`
  (values by field name; a choice picker selects the option whose value it
  is), and confirms through the prompt's `confirm_label` when one is
  declared.
  """
  @spec perform(struct(), map(), map()) :: struct()
  def perform(conn, %{id: row_id, text: row_text, inputs: inputs}, row_action) do
    conn = wait_for_row(conn, row_id, row_text, row_action)
    conn = click(conn, row_id, row_text, row_action)

    conn =
      Enum.reduce(row_action[:prompt_fields] || [], conn, fn field, acc ->
        fill_prompt(acc, field, Map.fetch!(inputs || %{}, field.name))
      end)

    case row_action[:confirm_label] do
      nil -> conn
      label -> confirm(conn, label)
    end
  end

  # The prompt's confirm control, clicked by its accessible name — but only
  # the visible one: a card with several actions (the tasks board renders
  # Complete and Delegate together) keeps every prompt's confirm in the DOM,
  # closed dialogs included, and a text-only click lands in the first of
  # them. Only the clicked action's prompt is open, so the visible confirm
  # is the right one.
  defp confirm(conn, label) do
    expression = """
    (() => {
      #{Browser.walker()}
      const label = #{Jason.encode!(label)}
      const visible = (el) => !!(el.offsetParent || el.getClientRects().length)
      const named = (el) =>
        (el.getAttribute("aria-label") || el.textContent || "").trim() === label
      const candidates = deep(document, "button, atlas-button").filter(
        (el) =>
          named(el) &&
          (visible(el) ||
            (el.shadowRoot && [...el.shadowRoot.querySelectorAll("button")].some(visible)))
      )
      const el = candidates[0]
      if (!el) return false
      const inner = el.shadowRoot && el.shadowRoot.querySelector("button")
      ;(inner || el).click()
      return true
    })()
    """

    case eval(conn, expression) do
      true ->
        conn

      _missing ->
        raise ExUnit.AssertionError,
          message: "no visible confirm control named #{inspect(label)}"
    end
  end

  # The waits below poll the page with `Process.sleep/1` between reads. That
  # is deliberate, not the sleep the test guidelines forbid: the state waited on
  # lives in Chromium, another OS process, which sends the test no message
  # when it changes, so there is nothing to monitor or `assert_receive`.
  @wait_ms 30_000
  @poll_ms 200

  # The grid renders its rows after the surface's data model hydrates, so the
  # click waits for the row instead of racing it.
  defp wait_for_row(conn, row_id, row_text, row_action) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms

    expression =
      """
      (() => {
        #{Browser.walker()}
        return deep(document, `[__ROW_ATTR__=__ROW_ID__]`).length > 0 ? "yes" : "no"
      })()
      """
      |> String.replace("__ROW_ATTR__", row_attribute(row_action))
      |> String.replace("__ROW_ID__", Jason.encode!(row_id))

    do_wait_for_row(conn, expression, deadline, row_text)
  end

  defp do_wait_for_row(conn, expression, deadline, row_text) do
    case eval(conn, expression) do
      "yes" ->
        conn

      _missing ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@poll_ms)
          do_wait_for_row(conn, expression, deadline, row_text)
        else
          state =
            eval(conn, """
            (() => {
              #{Browser.walker()}
              return JSON.stringify({
                rows: deep(document, "[data-a2ui-row-id]").length,
                actions: deep(document, "[data-a2ui-action]").length,
                grid: deep(document, "[data-a2ui-id]").map((el) => el.getAttribute("data-a2ui-id"))
              })
            })()
            """)

          raise ExUnit.AssertionError,
            message: "the row for #{inspect(row_text)} never rendered; page state: #{state}"
        end
    end
  end

  # Clicks the row action `label` inside the row found by its
  # `data-a2ui-row-id`. The control is found by its accessible name (the
  # manifest's `label`, read through shadow roots); the native button under
  # it receives the click.
  defp click(conn, row_id, row_text, row_action) do
    row_attribute = row_attribute(row_action)
    action_attribute = action_attribute(row_action)

    # The manifest's own selector is `[data-a2ui-action="<action>"]`; scoping
    # it to the row keeps a label shared by two actions unambiguous.
    expression = """
    (() => {
      #{Browser.walker()}
      #{@deep_text_js}
      const row = deep(document, `[__ROW_ATTR__=__ROW_ID__]`)[0]
      if (!row) return "no row"
      const controls = deep(row, `[__ACTION_ATTR__]`).flatMap((el) => [
        el,
        ...(el.shadowRoot ? deep(el.shadowRoot, "button, a") : [])
      ])
      const label = __LABEL__
      const byName = (el) =>
        (el.getAttribute("aria-label") || deepText(el) || "").trim() === label
      const control =
        controls.find(byName) || deep(row, "button, a, atlas-button").find(byName)
      if (!control) return "no control named " + label
      // The click lands on the native button a person presses: the first
      // button or link under the control, through shadow roots (an
      // atlas-a2ui-button wraps an atlas-button whose own shadow root draws
      // the button), so it bubbles through every host's listener.
      const native = control.matches("button, a")
        ? control
        : [control, ...(control.shadowRoot ? [control.shadowRoot] : [])]
            .flatMap((root) => deep(root, "button, a"))[0]
      ;(native || control).click()
      return "clicked"
    })()
    """

    expression =
      expression
      |> String.replace("__ROW_ATTR__", row_attribute)
      |> String.replace("__ACTION_ATTR__", action_attribute)
      |> String.replace("__ROW_ID__", Jason.encode!(row_id))
      |> String.replace("__LABEL__", Jason.encode!(row_action.label))

    case eval(conn, expression) do
      "clicked" ->
        conn

      outcome ->
        raise ExUnit.AssertionError,
          message:
            "row action #{inspect(row_action.label)} in row #{inspect(row_text)} " <>
              "(id #{inspect(row_id)}): #{outcome}"
    end
  end

  defp row_attribute(row_action), do: attributes(row_action).row_id
  defp action_attribute(row_action), do: attributes(row_action).action

  # The attributes the manifest lists, carried per surface; a row action map
  # may carry them (`attributes:`), else version 1's names.
  defp attributes(row_action) do
    row_action[:attributes] || %{row_id: "data-a2ui-row-id", action: "data-a2ui-action"}
  end

  defp fill_prompt(conn, %{widget: :choice_picker} = field, value) do
    option =
      Enum.find_value(field[:options] || [], fn opt ->
        if opt.value == to_string(value), do: opt.label
      end) ||
        raise ArgumentError,
              "prompt field #{inspect(field.label)} has no option #{inspect(value)}"

    PhoenixTest.select(conn, field.label, option: option)
  end

  defp fill_prompt(conn, %{widget: :check_box} = field, true),
    do: PhoenixTest.check(conn, field.label)

  defp fill_prompt(conn, %{widget: :check_box} = field, false),
    do: PhoenixTest.uncheck(conn, field.label)

  defp fill_prompt(conn, field, value) when is_struct(value, DateTime) do
    PhoenixTest.fill_in(conn, field.label,
      with: DateTime.to_iso8601(value) |> String.slice(0, 16)
    )
  end

  defp fill_prompt(conn, field, value) when is_struct(value, Date),
    do: PhoenixTest.fill_in(conn, field.label, with: Date.to_iso8601(value))

  defp fill_prompt(conn, field, value), do: PhoenixTest.fill_in(conn, field.label, with: value)

  defp eval(conn, expression) do
    parent = self()
    ref = make_ref()
    PhoenixTest.Playwright.evaluate(conn, expression, &send(parent, {ref, &1}))

    receive do
      {^ref, result} -> result
    after
      5_000 -> raise ExUnit.AssertionError, message: "the page did not answer evaluate"
    end
  end
end
