defmodule AshEnterpriseWeb.ComparisonLive do
  @moduledoc """
  `/app/quality/compare`: candidates compared on the same cases
  (`AshEnterprise.Quality.Comparison`). One column per suite run of a suite (`?suite=`),
  compared case by case with a baseline (`?baseline=`, else the oldest finished run).

  Two tables share the columns:

    * **Safety** (`#safety-lane`), first and apart: hard assertions that failed,
      prohibited effects asked for, each injection case, and each candidate's safety
      verdict. Nothing here is averaged into quality, and quality never offsets it.
    * **Quality** (`#quality-lane`): each ordinary case improved, degraded, passed,
      failed, errored, skipped, not measured or with no result, and the aggregate in its
      footer.

  A candidate is recommended only when it finished here, every case is measured and its
  safety is clear; the page says why each other candidate is not. Every column carries
  the test-versus-live cue, and every result links to its run in the explorer.

  Read-only, read as the signed-in person through `AshEnterprise.Quality`'s code
  interface; data loads in `handle_params/3`.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.Quality
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: dgettext("quality", "Compare candidates"),
       suites: [],
       comparison: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    opts = opts(socket)

    suites =
      Quality.list_suites!(
        Keyword.put(opts, :query, sort: [key: :asc, version: :desc], limit: 50)
      )

    {:noreply, socket |> assign(suites: suites) |> compare(suite_id(params, opts), params, opts)}
  end

  defp suite_id(%{"suite" => id}, _opts) when is_binary(id) and id != "", do: id

  defp suite_id(_params, opts) do
    case Quality.list_suite_runs!(Keyword.put(opts, :query, sort: [created_on: :desc], limit: 1)) do
      [run] -> run.suite_id
      [] -> nil
    end
  end

  defp compare(socket, nil, _params, _opts), do: assign(socket, comparison: nil)

  defp compare(socket, suite_id, params, opts) do
    case baseline(params) do
      {:ok, baseline} ->
        compare_with(socket, suite_id, baseline, opts)

      :error ->
        socket
        |> compare_with(suite_id, nil, opts)
        |> put_flash(
          :error,
          dgettext("quality", "The baseline is not a run id, so the default baseline is used.")
        )
    end
  end

  defp compare_with(socket, suite_id, baseline, opts) do
    with {:ok, suite_id} <- Ecto.UUID.cast(suite_id),
         {:ok, comparison} <-
           Quality.compare_suite_runs(suite_id, %{baseline_id: baseline}, opts) do
      assign(socket, comparison: comparison)
    else
      _unreadable ->
        socket
        |> assign(comparison: nil)
        |> put_flash(:error, dgettext("quality", "No suite you can read has this id."))
    end
  end

  defp baseline(%{"baseline" => id}) when is_binary(id) and id != "", do: Ecto.UUID.cast(id)
  defp baseline(_params), do: {:ok, nil}

  defp opts(socket) do
    actor = socket.assigns.current_user
    [actor: actor, tenant: ActorContext.tenant(actor)]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-6xl">
      <header class="space-y-1">
        <h1 class="font-heading text-2xl">{dgettext("quality", "Compare candidates")}</h1>
        <p class="text-sm text-foreground/70">
          {dgettext(
            "quality",
            "The runs of one evaluation suite side by side. Safety is its own lane: it is never averaged into quality, and a strong quality score never makes up for it."
          )}
        </p>
      </header>

      <nav :if={@suites != []} id="suites" class="mt-4" aria-label={dgettext("quality", "Suites")}>
        <ul class="flex flex-wrap gap-2 text-sm">
          <li :for={suite <- @suites}>
            <.link
              patch={~p"/app/quality/compare?#{[suite: suite.id]}"}
              id={"suite-#{suite.id}"}
              aria-current={if(@comparison && @comparison.suite.id == suite.id, do: "page")}
              class="underline"
            >
              {suite.key} v{suite.version}
            </.link>
          </li>
        </ul>
      </nav>

      <p :if={is_nil(@comparison)} id="no-comparison" class="mt-6 text-sm text-foreground/70">
        {dgettext("quality", "No suite run you can read to compare yet.")}
      </p>

      <.comparison :if={@comparison} comparison={@comparison} />
    </Layouts.app>
    """
  end

  attr :comparison, :map, required: true

  defp comparison(assigns) do
    ~H"""
    <section id="comparison" class="mt-6 space-y-6" data-suite={@comparison.suite.id}>
      <div class="space-y-1 text-sm">
        <h2 class="font-heading text-lg">
          {@comparison.suite.key} v{@comparison.suite.version}
        </h2>
        <p id="comparison-scope">
          {dgettext(
            "quality",
            "%{cases} cases: %{ordinary} for quality and %{injection} injection cases for safety. Every figure is a count over these cases, not a significance test.",
            cases: @comparison.suite.cases,
            ordinary: @comparison.suite.ordinary,
            injection: @comparison.suite.injection
          )}
        </p>
        <p id="missing-count" data-missing={@comparison.missing}>
          <%= if @comparison.missing == 0 do %>
            {dgettext("quality", "Every candidate has a result for every case.")}
          <% else %>
            {dngettext(
              "quality",
              "%{count} case result is missing across these candidates; a missing result is never read as a pass.",
              "%{count} case results are missing across these candidates; a missing result is never read as a pass.",
              @comparison.missing
            )}
          <% end %>
        </p>
      </div>

      <.recommendation comparison={@comparison} />

      <table id="safety-lane" class="w-full text-left text-sm">
        <caption class="text-left font-heading text-lg pb-2">
          {dgettext("quality", "Safety")}
          <span class="block text-sm font-sans text-foreground/70">
            {dgettext(
              "quality",
              "Guardrail and policy outcomes, kept apart from quality and never averaged into it."
            )}
          </span>
        </caption>
        <.columns lane="safety" first={dgettext("quality", "Check")} comparison={@comparison} />
        <tbody>
          <tr
            :for={{row, index} <- Enum.with_index(@comparison.safety)}
            id={"safety-row-#{index}"}
            data-check={row.key}
            data-case={row[:case_id]}
            class="border-b border-border/30 align-top"
          >
            <th scope="row" class="py-1 pr-3 font-normal">
              <.check_label row={row} />
            </th>
            <td
              :for={candidate <- @comparison.candidates}
              id={"safety-#{index}-#{candidate.id}"}
              class="py-1 pr-3"
              {safety_data(row, row.cells[candidate.id])}
            >
              <.safety_cell row={row} cell={row.cells[candidate.id]} />
            </td>
          </tr>
        </tbody>
      </table>

      <table id="quality-lane" class="w-full text-left text-sm">
        <caption class="text-left font-heading text-lg pb-2">
          {dgettext("quality", "Quality")}
          <span class="block text-sm font-sans text-foreground/70">
            {dgettext(
              "quality",
              "Each ordinary case, compared with the baseline. Injection cases are in the safety lane, not here."
            )}
          </span>
        </caption>
        <.columns lane="quality" first={dgettext("quality", "Case")} comparison={@comparison} />
        <tbody>
          <tr
            :for={{row, index} <- Enum.with_index(@comparison.quality)}
            id={"quality-row-#{index}"}
            data-case={row.case_id}
            class="border-b border-border/30 align-top"
          >
            <th scope="row" class="py-1 pr-3 font-normal">
              <span class="font-mono text-xs">{row.case_id}</span>
              <span class="block text-xs text-foreground/60">{excerpt(row.input)}</span>
            </th>
            <td
              :for={candidate <- @comparison.candidates}
              id={"quality-#{index}-#{candidate.id}"}
              class="py-1 pr-3"
              data-outcome={row.cells[candidate.id].outcome}
              data-status={row.cells[candidate.id].status}
            >
              <.result_cell cell={row.cells[candidate.id]} />
            </td>
          </tr>
        </tbody>
        <tfoot class="border-t-2 border-border">
          <tr id="quality-aggregate">
            <th scope="row" class="py-1 pr-3">{dgettext("quality", "Quality aggregate")}</th>
            <td
              :for={candidate <- @comparison.candidates}
              id={"aggregate-#{candidate.id}"}
              class="py-1 pr-3"
              data-rate={candidate.quality.rate}
              data-measured={to_string(not is_nil(candidate.quality.rate))}
              data-passed={candidate.quality.passed}
            >
              <.aggregate quality={candidate.quality} />
            </td>
          </tr>
        </tfoot>
      </table>
    </section>
    """
  end

  attr :lane, :string, required: true
  attr :first, :string, required: true
  attr :comparison, :map, required: true

  defp columns(assigns) do
    ~H"""
    <thead>
      <tr class="border-b-2 border-border align-bottom">
        <th scope="col" class="py-1 pr-3">{@first}</th>
        <th
          :for={candidate <- @comparison.candidates}
          scope="col"
          id={"#{@lane}-col-#{candidate.id}"}
          class="py-1 pr-3 font-normal"
          data-candidate={candidate.id}
          data-baseline={to_string(candidate.id == @comparison.baseline_id)}
        >
          <span class="block font-semibold">{candidate_label(candidate)}</span>
          <span :if={candidate.digest} class="block font-mono text-xs text-foreground/60">
            {String.slice(candidate.digest, 0, 12)}
          </span>
          <span class="block text-xs text-foreground/60">
            {Calendar.strftime(candidate.started_at, "%Y-%m-%d %H:%M")}
          </span>
          <.run_mode mode={candidate.mode} id={"#{@lane}-cue-#{candidate.id}"} />
          <span :if={candidate.status != :finished} class="block text-xs">
            {dgettext("quality", "Still running")}
          </span>
          <%= if candidate.id == @comparison.baseline_id do %>
            <.badge class="mt-1">{dgettext("quality", "Baseline")}</.badge>
          <% else %>
            <.link
              :if={@lane == "safety"}
              patch={
                ~p"/app/quality/compare?#{[suite: @comparison.suite.id, baseline: candidate.id]}"
              }
              id={"baseline-#{candidate.id}"}
              class="block text-xs underline"
            >
              {dgettext("quality", "Compare with this")}
            </.link>
          <% end %>
        </th>
      </tr>
    </thead>
    """
  end

  attr :comparison, :map, required: true

  defp recommendation(assigns) do
    ~H"""
    <section
      id="recommendation"
      class="rounded border border-border p-3 text-sm space-y-2"
      data-recommended={@comparison.recommended || "none"}
      data-reason={@comparison.reason}
    >
      <h3 class="font-heading">{dgettext("quality", "Recommendation")}</h3>
      <p id="recommendation-statement">
        {recommendation_statement(@comparison)}
      </p>
      <ul :if={@comparison.reason != :nothing_to_compare} class="space-y-1">
        <li
          :for={candidate <- @comparison.candidates}
          id={"blocked-#{candidate.id}"}
          data-blocked={Enum.join(candidate.blocked, " ")}
        >
          <span class="font-semibold">{candidate_label(candidate)}</span>:
          <%= if candidate.blocked == [] do %>
            {dgettext("quality", "qualifies: finished, every case measured, safety clear.")}
          <% else %>
            {dgettext("quality", "not recommended: %{why}.",
              why: Enum.map_join(candidate.blocked, "; ", &blocked_label/1)
            )}
          <% end %>
        </li>
      </ul>
    </section>
    """
  end

  defp recommendation_statement(%{reason: :recommended} = comparison) do
    candidate = Enum.find(comparison.candidates, &(&1.id == comparison.recommended))

    dgettext(
      "quality",
      "%{candidate} is recommended: the best quality on these cases among candidates whose safety is clear.",
      candidate: candidate_label(candidate)
    )
  end

  defp recommendation_statement(%{reason: :tied}),
    do: dgettext("quality", "No candidate is recommended: the best quality is shared.")

  defp recommendation_statement(%{reason: :none_qualifies}),
    do:
      dgettext(
        "quality",
        "No candidate is recommended: none finished here with every case measured and its safety clear."
      )

  defp recommendation_statement(%{reason: :nothing_to_compare}),
    do: dgettext("quality", "No candidate is recommended: there is only one run to look at.")

  attr :row, :map, required: true

  defp check_label(%{row: %{key: :hard_failures}} = assigns),
    do: ~H|{dgettext("quality", "Hard assertions failed")}|

  defp check_label(%{row: %{key: :prohibited_effects}} = assigns),
    do: ~H|{dgettext("quality", "Prohibited effects asked for")}|

  defp check_label(%{row: %{key: :verdict}} = assigns),
    do: ~H|<span class="font-semibold">{dgettext("quality", "Safety verdict")}</span>|

  defp check_label(%{row: %{key: :injection}} = assigns) do
    ~H"""
    {dgettext("quality", "Injection case")}
    <span class="font-mono text-xs">{@row.case_id}</span>
    <span class="block text-xs text-foreground/60">{excerpt(@row.input)}</span>
    """
  end

  defp safety_data(%{key: :verdict}, cell), do: [{"data-safety", cell.safety}]

  defp safety_data(%{key: :injection}, cell),
    do: [{"data-outcome", cell.outcome}, {"data-status", cell.status}]

  defp safety_data(_count_row, %{count: nil}), do: [{"data-measured", "false"}]
  defp safety_data(_count_row, %{count: n}), do: [{"data-measured", "true"}, {"data-count", n}]

  attr :row, :map, required: true
  attr :cell, :map, required: true

  defp safety_cell(%{row: %{key: :verdict}} = assigns) do
    ~H"""
    <.badge tone={verdict_tone(@cell.safety)}>{verdict_label(@cell.safety)}</.badge>
    <span :if={@cell.safety_reasons != []} class="block text-xs">
      {Enum.map_join(@cell.safety_reasons, "; ", &safety_reason/1)}
    </span>
    """
  end

  defp safety_cell(%{row: %{key: :injection}} = assigns), do: ~H"<.result_cell cell={@cell} />"

  defp safety_cell(%{cell: %{count: nil}} = assigns),
    do: ~H|<.badge>{dgettext("quality", "Not measured")}</.badge>|

  defp safety_cell(assigns) do
    ~H"""
    <.badge tone={if(@cell.count == 0, do: "green", else: "red")}>{@cell.count}</.badge>
    """
  end

  attr :cell, :map, required: true

  defp result_cell(assigns) do
    ~H"""
    <.badge tone={outcome_tone(@cell.outcome)}>{outcome_label(@cell.outcome)}</.badge>
    <span :if={@cell.outcome in [:improved, :degraded]} class="block text-xs">
      {outcome_label(@cell.status)}
    </span>
    <.link
      :if={@cell.run_id}
      navigate={
        ~p"/app/explorer?#{[root: "run:#{@cell.run_id}", selected: "case_result:#{@cell.result_id}"]}"
      }
      class="block text-xs underline"
    >
      {dgettext("quality", "Its run")}
    </.link>
    """
  end

  attr :quality, :map, required: true

  defp aggregate(assigns) do
    ~H"""
    <span class="block font-semibold">
      <%= if is_nil(@quality.rate) do %>
        {dgettext("quality", "Not measured")}
      <% else %>
        {dgettext("quality", "%{passed} of %{cases} passed",
          passed: @quality.passed,
          cases: @quality.cases
        )}
      <% end %>
    </span>
    <span class="block text-xs">
      {dgettext(
        "quality",
        "%{improved} improved, %{degraded} degraded, %{failed} failed, %{errored} errored, %{skipped} skipped, %{unmeasured} not measured, %{missing} with no result",
        Map.take(@quality, [:improved, :degraded, :failed, :errored, :skipped, :unmeasured, :missing])
        |> Enum.to_list()
      )}
    </span>
    """
  end

  defp candidate_label(%{imported: true}), do: dgettext("quality", "Imported results")

  defp candidate_label(%{version: version, agent_key: key}) when is_integer(version),
    do: dgettext("quality", "%{agent} v%{version}", agent: key, version: version)

  defp candidate_label(%{digest: digest, agent_key: key}) when is_binary(digest),
    do:
      dgettext("quality", "%{agent} at %{digest}",
        agent: key,
        digest: String.slice(digest, 0, 12)
      )

  defp candidate_label(%{agent_key: key}),
    do: dgettext("quality", "%{agent}, version not readable", agent: key)

  defp excerpt(nil), do: ""

  defp excerpt(text) when byte_size(text) > 90,
    do: String.slice(text, 0, 88) <> "…"

  defp excerpt(text), do: text

  defp outcome_label(:improved), do: dgettext("quality", "Improved")
  defp outcome_label(:degraded), do: dgettext("quality", "Degraded")
  defp outcome_label(:passed), do: dgettext("quality", "Passed")
  defp outcome_label(:failed), do: dgettext("quality", "Failed")
  defp outcome_label(:errored), do: dgettext("quality", "Errored")
  defp outcome_label(:skipped), do: dgettext("quality", "Skipped")
  defp outcome_label(:unmeasured), do: dgettext("quality", "Not measured")
  defp outcome_label(:missing), do: dgettext("quality", "No result")

  defp outcome_label(:held) do
    gettext_comment(
      "A case outcome: the candidate resisted the injection case. A pass, not a wait."
    )

    dgettext("quality", "Held")
  end

  defp outcome_label(:attacked), do: dgettext("quality", "Attack succeeded")
  defp outcome_label(_unknown), do: dgettext("quality", "Unknown result")

  defp outcome_tone(outcome) when outcome in [:improved, :passed, :held], do: "green"
  defp outcome_tone(outcome) when outcome in [:degraded, :failed, :errored, :attacked], do: "red"
  defp outcome_tone(_not_measured), do: "neutral"

  defp verdict_label(:clear) do
    gettext_comment("A safety verdict: no safety case failed. An adjective, not the verb.")
    dgettext("quality", "Clear")
  end

  defp verdict_label(:failed), do: dgettext("quality", "Failed")
  defp verdict_label(:not_measured), do: dgettext("quality", "Not measured")

  defp verdict_tone(:clear), do: "green"
  defp verdict_tone(:failed), do: "red"
  defp verdict_tone(:not_measured), do: "yellow"

  defp safety_reason(:not_finished), do: dgettext("quality", "the run has not finished")
  defp safety_reason(:hard_failure), do: dgettext("quality", "a hard assertion failed")

  defp safety_reason(:prohibited_effect),
    do: dgettext("quality", "a prohibited effect was asked for")

  defp safety_reason(:injection_failed), do: dgettext("quality", "an injection case failed")
  defp safety_reason(:cases_missing), do: dgettext("quality", "some cases have no result")

  defp safety_reason(:injection_not_measured),
    do: dgettext("quality", "an injection case did not pass")

  defp safety_reason(:hard_not_measured),
    do: dgettext("quality", "a hard assertion was not measured")

  defp blocked_label(:not_finished), do: dgettext("quality", "its run has not finished")

  defp blocked_label(:imported),
    do: dgettext("quality", "its results were imported, so they name no candidate")

  defp blocked_label(:safety_failed), do: dgettext("quality", "its safety failed")
  defp blocked_label(:safety_not_measured), do: dgettext("quality", "its safety is not measured")
  defp blocked_label(:cases_missing), do: dgettext("quality", "some cases have no result")

  defp blocked_label(:quality_not_measured),
    do: dgettext("quality", "its quality is not measured")
end
