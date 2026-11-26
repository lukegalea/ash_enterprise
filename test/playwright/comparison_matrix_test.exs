defmodule AshEnterpriseWeb.Specs.ComparisonMatrixTest do
  use Playwright.Case, async: true

  import AshEnterpriseWeb.Specs.SignIn

  alias AshEnterpriseWeb.Specs.AxeBuilder
  alias AshEnterpriseWeb.Specs.Demo

  # Candidates compared (/app/quality/compare) in a real browser, on the clinic
  # demo. The licence reader's first version and its candidate are measured on
  # the same comparison suite, beside an imported partial log of the same suite
  # (AshEnterprise.Credentialing.ComparisonDemoData): the candidate is better on
  # quality and its injection case was attacked.
  #
  # The page shows improved, degraded, failed, skipped, not measured and missing
  # cases as distinct cells in words; keeps the injection case and every
  # guardrail outcome in a safety table of its own, apart from the quality
  # aggregate; recommends the first version, not the attacked candidate; carries
  # the test-versus-live cue on every column; and passes axe's WCAG 2.2 AA rules,
  # its two tables named by their captions (decision P5-5: an ARIA snapshot in
  # place of a manual screen-reader pass).
  #
  # Seed state: `mix ash_enterprise.demo` (support/demo.ex). Read-only: it runs
  # again on the same seed.

  @wcag22aa ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]
  @suite "credentialing.licence_reader.comparison"

  test "each outcome is distinct, safety is its own lane, and the attacked candidate is not recommended",
       %{page: page} do
    sign_in(page, %{email: Demo.admin(), password: Demo.password()})
    Page.goto!(page, "/app/quality/compare", wait_until: :networkidle)

    page
    |> Page.locator(".phx-connected")
    |> Locator.first()
    |> Locator.wait_for!(timeout: 15_000)

    page
    |> Page.get_by_role(:link,
      name: Regex.compile!("^#{String.replace(@suite, ".", "\\.")} v\\d+$")
    )
    |> Locator.click!()

    Expect.to_contain_text!(Page.locator(page, "#comparison h2"), @suite)
    Expect.to_be_visible!(Page.locator(page, "#context-band"))

    quality = Page.get_by_role(page, :table, name: ~r/^Quality/)
    safety = Page.get_by_role(page, :table, name: ~r/^Safety/)
    Expect.to_be_visible!(quality)
    Expect.to_be_visible!(safety)

    # Each outcome is its own cell, said in words, and no two read alike.
    outcomes = [
      improved: "Improved",
      degraded: "Degraded",
      failed: "Failed",
      skipped: "Skipped",
      unmeasured: "Not measured",
      missing: "No result"
    ]

    seen =
      for {outcome, label} <- outcomes, into: MapSet.new() do
        cell =
          page
          |> Page.locator("#quality-lane tbody td[data-outcome='#{outcome}']")
          |> Locator.first()

        cell |> Expect.message("a #{outcome} cell") |> Expect.to_be_visible!()

        text =
          cell
          |> Locator.locator("span")
          |> Locator.first()
          |> Locator.inner_text!()
          |> String.trim()

        assert text == label
        text
      end

    assert MapSet.size(seen) == length(outcomes)

    # Not measured is never a zero or a pass.
    unmeasured =
      page
      |> Page.locator("#quality-lane tbody td[data-outcome='unmeasured']")
      |> Locator.first()

    Expect.not_to_contain_text!(unmeasured, "Passed")
    Expect.not_to_have_text!(unmeasured, ~r/^\s*0\s*$/)

    # Missing results are counted and shown.
    missing =
      page
      |> Page.locator("#missing-count")
      |> Locator.get_attribute!("data-missing")
      |> String.to_integer()

    assert missing > 0

    Expect.to_contain_text!(
      Page.locator(page, "#missing-count"),
      "#{missing} case results are missing"
    )

    # The injection case is in the safety lane, never in the quality lane.
    Expect.to_have_count!(Page.locator(page, "#quality-lane tr[data-case='injected']"), 0)

    attacked =
      Page.locator(page, "#safety-lane tr[data-case='injected'] td[data-outcome='attacked']")

    Expect.to_have_count!(attacked, 1)
    Expect.to_contain_text!(attacked, "Attack succeeded")

    candidate_id =
      attacked |> Locator.get_attribute!("id") |> String.replace(~r/^safety-\d+-/, "")

    # Its quality aggregate stands, and does not buy back its safety.
    Expect.to_contain_text!(Page.locator(page, "#aggregate-#{candidate_id}"), "3 of 6 passed")

    page
    |> Page.locator("#safety-lane tr[data-check='verdict'] td[id$='-#{candidate_id}']")
    |> Expect.to_have_attribute!("data-safety", "failed")

    Expect.to_have_attribute!(
      Page.locator(page, "#blocked-#{candidate_id}"),
      "data-blocked",
      ~r/safety_failed/
    )

    # The first version, the baseline, is the one recommended.
    baseline = Page.locator(page, "#quality-lane thead th[data-baseline='true']")
    baseline_id = Locator.get_attribute!(baseline, "data-candidate")

    Expect.to_have_attribute!(
      Page.locator(page, "#recommendation"),
      "data-recommended",
      baseline_id
    )

    Expect.not_to_have_attribute!(
      Page.locator(page, "#recommendation"),
      "data-recommended",
      candidate_id
    )

    # Every column says it is a test run.
    cues = Page.locator(page, "#quality-lane thead [data-run-environment]")
    Expect.to_have_count!(cues, 3)

    for environment <-
          Locator.evaluate_all!(
            cues,
            ~s|(els) => els.map((el) => el.getAttribute("data-run-environment"))|
          ),
        do: assert(environment == "test")

    Expect.not_to_contain_text!(Page.locator(page, "#comparison"), ~r/live run/i)

    # Two tables, each named by its caption, each with its candidates as column headers.
    Expect.to_match_aria_snapshot!(safety, """
    - table:
      - caption: /Safety/
      - rowgroup:
        - row:
          - columnheader "Check"
    """)

    Expect.to_have_count!(Locator.get_by_role(quality, :columnheader), 4)
    Expect.to_be_visible!(Locator.get_by_role(quality, :rowheader, name: ~r/steady/))

    results = AxeBuilder.new(page) |> AxeBuilder.with_tags(@wcag22aa) |> AxeBuilder.analyze!()
    assert results["violations"] == []
  end
end
