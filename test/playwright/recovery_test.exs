defmodule AshEnterpriseWeb.Specs.RecoveryTest do
  use Playwright.Case, async: true, group: :activations

  alias AshEnterpriseWeb.Specs.Demo

  # The recovery surface in a real browser (AGT-62): an activation whose answer the
  # registry lost, settled by a person, then simulated, rerun and cancelled.
  #
  # The uncertain outcome comes from the showcase's fault panel, the dev configuration's
  # demo-only controls (`config/dev.exs`, `fault_controls?: true`), never from seeded
  # history: the coordinator arms "Lose the registry's answer" and asks to activate a
  # credential; a committee member approves it; the registry accepts the activation and
  # the answer is lost, and the registry cannot say afterwards whether it took it. The
  # request is then uncertain and waits for a person.
  #
  # Seed state: the demo tenant (`mix ash_enterprise.demo`): the coordinator
  # rosa@example.com, the committee member kenji@example.com and the administrator
  # demo-admin@example.com, all with the demo password (support/demo.ex).
  #
  # The approval is applied by its minute sweep and the activation then runs as a job, so
  # the uncertain row can take a minute or more to appear. It runs one at a time with
  # execution_explorer_test.exs (its `group:`): both run an activation.

  @coordinator "rosa@example.com"
  @committee "kenji@example.com"
  @admin Demo.admin()

  defp signed_in(browser, email) do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/sign-in", wait_until: :networkidle)
    # The sign-in form is a LiveView: fill it once it has connected.
    page
    |> Page.locator(".phx-connected")
    |> Locator.first()
    |> Locator.wait_for!(timeout: 15_000)

    Page.fill!(page, ~s(input[type="email"]), email)
    Page.fill!(page, ~s(input[type="password"]), Demo.password())
    Page.click!(page, ~s(button[type="submit"]))
    Page.wait_for_url!(page, &(!String.contains?(&1.path, "sign-in")), timeout: 15_000)
    page
  end

  defp connected(page, path) do
    Page.goto!(page, path, wait_until: :networkidle)

    page
    |> Page.locator(".phx-connected")
    |> Locator.first()
    |> Locator.wait_for!(timeout: 15_000)
  end

  @tag timeout: 300_000
  test "an uncertain outcome is settled, simulated, rerun and cancelled, each act recorded",
       %{browser: browser} do
    # The coordinator arms the fault and asks to activate a credential.
    rosa = signed_in(browser, @coordinator)
    connected(rosa, "/app/showcase/credentialing")
    rosa |> Page.locator("#fault-lose") |> Locator.click!()
    Expect.to_contain_text!(Page.locator(rosa, "#flash-info"), "Armed")

    ask = rosa |> Page.locator(~s([id^="raise-"])) |> Locator.first()
    Locator.click!(ask)
    Expect.to_contain_text!(Page.locator(rosa, "#flash-info"), "waits for approval")

    # The newest request waiting for approval. Its approval is the committee's, so the
    # coordinator's tour shows the request but no link to the approval.
    waiting_row =
      rosa |> Page.locator(~s(#all-rows tr[data-status="awaiting_approval"])) |> Locator.first()

    Expect.to_be_visible!(waiting_row, timeout: 15_000)

    invocation_id =
      waiting_row |> Locator.get_attribute!("id") |> String.replace("all-", "", global: false)

    Expect.to_have_count!(Page.locator(rosa, "#all-approve-#{invocation_id}"), 0)

    # A committee member opens it from the tour and approves it on the approvals surface.
    # The list holds every approval waiting on them, oldest first, and the seeded clinic
    # already has an activation waiting: this request is the newest row.
    kenji = signed_in(browser, @committee)
    connected(kenji, "/app/showcase/credentialing")

    approval_path =
      kenji |> Page.locator("#all-approve-#{invocation_id}") |> Locator.get_attribute!("href")

    connected(kenji, approval_path)

    waiting =
      kenji
      |> Page.get_by_role(:table, name: "approval")
      |> Locator.get_by_role(:row)
      |> Locator.filter(has_text: "activate_credential")

    Expect.to_be_visible!(Locator.last(waiting), timeout: 15_000)
    before = Locator.count!(waiting)

    waiting
    |> Locator.last()
    |> Locator.get_by_role(:button, name: "Approve", exact: true)
    |> Locator.click!()

    Expect.to_have_count!(waiting, before - 1, timeout: 15_000)

    # The operator finds it uncertain on the recovery surface.
    admin = signed_in(browser, @admin)
    connected(admin, "/app/recovery")

    Expect.to_be_visible!(Page.locator(admin, "#uncertain-rows-#{invocation_id}"),
      timeout: 180_000
    )

    connected(admin, "/app/recovery/#{invocation_id}")
    Expect.to_have_attribute!(Page.locator(admin, "#status"), "data-status", "uncertain")
    Expect.to_be_visible!(Page.locator(admin, "#settle-form"), timeout: 60_000)
    Expect.to_be_visible!(Page.locator(admin, "#settle-succeeded"))
    Expect.to_be_visible!(Page.locator(admin, "#settle-failed"))
    Expect.to_be_visible!(Page.locator(admin, "#settle-retry"))
    # No plain Retry, and no Rerun, while the outcome is uncertain.
    Expect.to_have_count!(Page.get_by_role(admin, :button, name: ~r/^retry$/i), 0)
    Expect.to_have_count!(Page.locator(admin, "#rerun-form"), 0)

    # Settled as not done, with a reason.
    admin |> Page.locator("#settle-failed") |> Locator.check!()
    admin |> Page.locator("#settle-reason") |> Locator.fill!("The registry has no record of it.")
    admin |> Page.locator("#settle") |> Locator.click!()

    Expect.to_have_attribute!(Page.locator(admin, "#status"), "data-status", "failed",
      timeout: 60_000
    )

    # Rerun says what will run again before anyone asks.
    statement = Page.locator(admin, "#rerun-statement")
    Expect.to_contain_text!(statement, "new key")
    Expect.to_contain_text!(statement, "calls outside the application again")

    # Simulate creates nothing.
    admin |> Page.locator("#simulate") |> Locator.click!()
    Expect.to_contain_text!(Page.locator(admin, "#simulation"), "Nothing was created")
    Expect.to_have_count!(Page.locator(admin, "#reruns"), 0)

    # Rerun: a new request with a new key, linked to the first.
    first_key = admin |> Page.locator("#invocation-key") |> Locator.inner_text!()
    admin |> Page.locator("#rerun-reason") |> Locator.fill!("Ask the registry again.")
    admin |> Page.locator("#rerun") |> Locator.click!()

    Expect.to_have_attribute!(
      Page.locator(admin, "#rerun-of"),
      "href",
      "/app/recovery/#{invocation_id}",
      timeout: 15_000
    )

    Expect.not_to_have_text!(Page.locator(admin, "#invocation-key"), first_key)
    Expect.to_contain_text!(Page.locator(admin, "#invocation-key"), "rerun:#{invocation_id}:")
    Expect.to_have_attribute!(Page.locator(admin, "#status"), "data-status", "waiting")

    # Cancel says completed effects are not reversed.
    Expect.to_contain_text!(
      Page.locator(admin, "#cancel-statement"),
      "Completed effects are not reversed"
    )

    admin |> Page.locator("#cancel-reason") |> Locator.fill!("Asked twice by mistake.")
    admin |> Page.locator("#cancel") |> Locator.click!()

    Expect.to_have_attribute!(Page.locator(admin, "#status"), "data-status", "cancelled",
      timeout: 15_000
    )

    Page.screenshot!(admin,
      path: System.get_env("E2E_SCREENSHOT", "test-results/recovery-rerun.png"),
      full_page: true
    )

    # Every act on the first request, with who did it and why.
    connected(admin, "/app/recovery/#{invocation_id}")
    settled = Page.locator(admin, ~s(#interventions [data-act="resolve"]))
    Expect.to_contain_text!(settled, "The registry has no record of it.")
    Expect.to_have_text!(Locator.locator(settled, ".intervention-actor"), @admin)

    Expect.to_contain_text!(
      Page.locator(admin, ~s(#interventions [data-act="rerun"])),
      "Ask the registry again."
    )

    Expect.to_be_visible!(admin |> Page.locator("#reruns li") |> Locator.first())

    Page.screenshot!(admin,
      path: System.get_env("E2E_SCREENSHOT_SETTLED", "test-results/recovery-settled.png"),
      full_page: true
    )
  end
end
