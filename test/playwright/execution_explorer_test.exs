defmodule AshEnterpriseWeb.Specs.ExecutionExplorerTest do
  use Playwright.Case, async: true, group: :activations

  import AshEnterpriseWeb.Specs.SignIn

  alias AshEnterpriseWeb.Specs.AxeBuilder
  alias AshEnterpriseWeb.Specs.Demo

  # The execution explorer (/app/explorer) in a real browser, on the clinic
  # demo. The coordinator does a piece of work from the credentialing tour, in
  # one page and so under one correlation id: opens a credential's case and
  # routes it (a process run and a decision), has the licence reader read
  # another credential's documents (the evidence, and the judgments on it), and
  # asks to activate that credential. A committee member approves it; the
  # activation runs and the registry records it (the effect).
  #
  # The administrator then starts from the activation, and walks from its effect
  # to its approval, and from everything recorded with it to the decision's
  # matched rule, a judgment and the evidence it cites; the timeline, the
  # diagram and the detail show one selection; the page and the timeline pass
  # axe's WCAG 2.2 AA rules, and the timeline's accessibility tree is a log of
  # buttons (decision P5-5: an ARIA snapshot in place of a manual screen-reader
  # pass). The canvas being unavailable (QX-02) is the LiveView test's: it
  # sends the viewer's import error and selects from the timeline alone.
  #
  # Seed state: `mix ash_enterprise.demo` (support/demo.ex). The spec picks
  # whichever credentials are still unopened and pending, and follows the
  # request it raised itself, so it runs again on the same seed while the
  # clinic has a case left to open (four on a fresh seed). It runs one at a time
  # with recovery_test.exs (its `group:`): both run an activation.

  @wcag22aa ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]
  @coordinator "rosa@example.com"
  @committee "kenji@example.com"

  defp shot(name), do: "#{System.get_env("E2E_SCREENSHOT_DIR", "test-results")}/#{name}.png"

  defp connected(page, path) do
    Page.goto!(page, path, wait_until: :networkidle)

    page
    |> Page.locator(".phx-connected")
    |> Locator.first()
    |> Locator.wait_for!(timeout: 15_000)
  end

  defp as(browser, email) do
    page = browser |> Browser.new_context!() |> BrowserContext.new_page!()
    sign_in(page, %{email: email, password: Demo.password()})
    page
  end

  # The coordinator's work, in one tour page. Returns the activation's invocation id.
  defp work(page) do
    connected(page, "/app/showcase/credentialing")

    # A case, opened and routed: the process run and the decision.
    unopened = page |> Page.locator("li[id^=unopened-]") |> Locator.first()
    Expect.to_be_visible!(unopened)

    case_number =
      unopened
      |> Locator.locator("a")
      |> Locator.first()
      |> Locator.inner_text!()
      |> String.trim()

    unopened |> Locator.locator("button") |> Locator.click!()
    routed = Page.locator(page, "li[id^=routed-]", has_text: case_number)
    Expect.to_be_visible!(routed, timeout: 30_000)
    routed |> Locator.locator("button[id^=route-]") |> Locator.click!()

    page
    |> Page.locator("#flash-info, [role=status]")
    |> Locator.first()
    |> Expect.to_be_attached!()

    # A credential that is still pending and has a recorded reading.
    readable = Page.locator(page, "li[id^=readable-]")
    numbers = readable |> Locator.locator("a") |> Locator.all_inner_texts!()
    pending = page |> Page.locator("li[id^=pending-] a") |> Locator.all_inner_texts!()

    number =
      numbers
      |> Enum.map(&String.trim/1)
      |> Enum.find(&(&1 in Enum.map(pending, fn p -> String.trim(p) end)))

    assert number not in [nil, ""], "a pending credential with a recorded reading"

    readable
    |> Locator.filter(has_text: number)
    |> Locator.locator("button[id^=read-]")
    |> Locator.click!()

    # The request this run raises: the awaiting row that was not there before.
    rows = Page.locator(page, "#awaiting-rows tr[id^=awaiting-]")
    before = MapSet.new(Locator.evaluate_all!(rows, "(trs) => trs.map((tr) => tr.id)"))

    page
    |> Page.locator("li[id^=pending-]", has_text: number)
    |> Locator.locator("button[id^=raise-]")
    |> Locator.click!()

    id =
      Expect.to_pass!(
        fn ->
          now = Locator.evaluate_all!(rows, "(trs) => trs.map((tr) => tr.id)")
          id = Enum.find(now, &(not MapSet.member?(before, &1))) || ""
          assert id != "", "the new request waits for approval"
          id
        end,
        timeout: 15_000
      )

    String.replace(id, "awaiting-", "", global: false)
  end

  @tag timeout: 240_000
  test "from the activation's effect to its approval, the matched rule, the judgment and the evidence",
       %{browser: browser} do
    coordinator = as(browser, @coordinator)
    invocation = work(coordinator)

    # A committee member approves it on the approvals surface (its row is the task's).
    member = as(browser, @committee)
    connected(member, "/app/showcase/credentialing")
    member |> Page.locator("#awaiting-approve-#{invocation}") |> Locator.click!()
    Expect.to_have_url!(member, ~r/ctx(\[|%5B)task(\]|%5D)=/)
    task = URI.decode_query(URI.parse(Page.url(member)).query || "")["ctx[task]"]

    member
    |> Page.locator("#row-#{task}")
    |> Locator.get_by_role(:button, name: "Approve", exact: true)
    |> Locator.click!()

    confirm =
      member
      |> Page.get_by_role(:dialog)
      |> Locator.get_by_role(:button, name: ~r/^Approve/)

    if match?({:ok, true}, Locator.is_visible(confirm)), do: Locator.click!(confirm)
    Expect.to_have_count!(Page.locator(member, "#row-#{task}"), 0, timeout: 15_000)

    # The activation runs within a minute of the approval.
    admin = as(browser, Demo.admin())
    ref = "invocation:#{invocation}"
    effect = Page.locator(admin, "#timeline [data-ref='effect:#{invocation}']")

    Expect.to_pass!(
      fn ->
        connected(admin, "/app/explorer?root=#{ref}")
        # Ran and recorded, not only accepted: an effect whose outcome is unknown is uncertain.
        Expect.to_have_attribute!(effect, "data-status", "succeeded", timeout: 2_000)
      end,
      timeout: 150_000,
      intervals: [5_000]
    )

    # The effect, then the operation it belongs under, then its approval.
    Locator.click!(effect)

    Expect.to_have_attribute!(
      Page.locator(admin, "#explorer-detail"),
      "data-ref",
      "effect:#{invocation}"
    )

    Expect.to_have_attribute!(effect, "aria-current", "true")

    Expect.to_have_attribute!(
      Page.locator(admin, "#detail-run-mode"),
      "data-run-environment",
      "live"
    )

    admin |> Page.locator("#detail-parent [data-ref='#{ref}']") |> Locator.click!()
    Expect.to_have_attribute!(Page.locator(admin, "#explorer-detail"), "data-ref", ref)

    approval =
      admin |> Page.locator("#detail-children [data-ref^='human_task:']") |> Locator.first()

    Locator.click!(approval)
    Expect.to_have_attribute!(Page.locator(admin, "#detail-record"), "data-record", "human_task")
    Expect.to_contain_text!(Page.locator(admin, "#detail-record"), "approved")

    # Everything recorded with the activation.
    admin |> Page.locator("#timeline [data-ref='#{ref}']") |> Locator.click!()
    admin |> Page.locator("#detail-correlation a") |> Locator.click!()
    Expect.to_have_url!(admin, ~r/correlation_id=/)

    # The decision and the rule that matched.
    admin |> Page.locator("#timeline [data-kind=decision]") |> Locator.first() |> Locator.click!()
    Expect.to_have_attribute!(Page.locator(admin, "#detail-record"), "data-record", "evaluation")
    Expect.to_contain_text!(Page.locator(admin, "#detail-record"), "rule_route")

    # A judgment and the evidence it cites.
    admin
    |> Page.locator("#timeline [data-ref^='judgment:']")
    |> Locator.first()
    |> Locator.click!()

    Expect.to_have_attribute!(Page.locator(admin, "#detail-record"), "data-record", "judgment")
    Expect.to_be_visible!(admin |> Page.locator("#detail-evidence li") |> Locator.first())

    # The evidence read: the reader's tool result.
    admin
    |> Page.locator("#timeline [data-kind=observation][data-ref^='step:']")
    |> Locator.first()
    |> Locator.click!()

    Expect.to_have_attribute!(Page.locator(admin, "#detail-record"), "data-record", "step")

    # One selection: a process event is highlighted on the diagram and in the detail.
    Expect.to_be_visible!(Page.locator(admin, "[id^=explorer-bpmn-]"))
    events = Page.locator(admin, "#timeline [data-kind=process_event]")
    count = Locator.count!(events)

    node =
      Enum.reduce_while(0..(count - 1)//1, nil, fn i, nil ->
        events |> Locator.nth(i) |> Locator.click!()
        node = admin |> Page.locator("#diagram-selection") |> Locator.get_attribute!("data-node")
        if node in [nil, ""], do: {:cont, nil}, else: {:halt, node}
      end)

    assert node not in [nil, ""], "a process event on an element of the diagram"

    admin
    |> Page.locator("[id^=explorer-bpmn-] [data-element-id='#{node}'].ash-bpmn-highlight")
    |> Expect.to_be_visible!()

    Expect.to_have_attribute!(
      Page.locator(admin, "#detail-record"),
      "data-record",
      "process_event"
    )

    Page.screenshot!(admin, path: shot("execution_explorer"), full_page: true)

    # The timeline is a log of buttons, reachable from the keyboard.
    Expect.to_match_aria_snapshot!(Page.locator(admin, "#timeline"), """
    - log:
      - list:
        - listitem:
          - button
    """)

    first = admin |> Page.locator("#timeline button") |> Locator.first()
    Locator.focus!(first)
    admin |> Page.keyboard() |> Keyboard.press!("Enter")
    Expect.to_have_attribute!(first, "aria-current", "true")

    results = AxeBuilder.new(admin) |> AxeBuilder.with_tags(@wcag22aa) |> AxeBuilder.analyze!()
    assert results["violations"] == []
  end
end
