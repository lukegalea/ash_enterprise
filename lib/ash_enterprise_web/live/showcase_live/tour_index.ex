defmodule AshEnterpriseWeb.ShowcaseLive.TourIndex do
  @moduledoc """
  The credentialing tour's index and its way into the explorer
  (`AshEnterpriseWeb.ShowcaseLive.Credentialing`).

    * `records/1` finds, from what the tour has already read, the record each beat shows:
      the newest request, run or case that is that beat's outcome, as an explorer root
      (`invocation:<id>`, `run:<id>`, `process_instance:<id>`). A beat with nothing to
      show has none, and says so: it never links to an empty page.
    * `index/1` is the F1–F12 table at the top of the tour: each failure, the beat that
      shows it, and its record in the explorer.
    * `explore/1` is a beat's own "open in explorer" link.
    * `history_note/1` replaces the demo-build note on a beat whose record the demo's
      history seed made (`mix ash_enterprise.demo --history`).

  Copy is in English through the `showcase` Gettext domain.
  """

  use AshEnterpriseWeb, :html

  @typedoc "An explorer root: `{type, id}`."
  @type root :: {:invocation | :run | :process_instance, String.t()}

  # The beats, in tour order: {number, dom id, failure or nil}.
  @beats [
    {1, "beat-raise", nil},
    {2, "beat-approve", nil},
    {3, "beat-stale", "F4"},
    {4, "beat-revoked", "F5"},
    {5, "beat-reconciled", "F2"},
    {6, "beat-read", nil},
    {7, "beat-timeout", "F1"},
    {8, "beat-budget", "F8"},
    {9, "beat-erase", "F11"},
    {10, "beat-case", nil},
    {11, "beat-checks", "F7"},
    {12, "beat-webhook", "F6"},
    {13, "beat-committee", nil},
    {14, "beat-timer", nil},
    {15, "beat-acp", nil},
    {16, "beat-candidate", "F9"},
    {17, "beat-routing", "F10"},
    {18, "beat-shadow", "F12"},
    {19, "beat-deploy", "F3"}
  ]

  @doc "The beats in tour order, each `{number, dom id, failure or nil}`."
  @spec beats() :: [{pos_integer(), String.t(), String.t() | nil}]
  def beats, do: @beats

  @doc "The failures F1 to F12, each with its beat: `[{failure, number, dom id}]`, in F order."
  @spec failures() :: [{String.t(), pos_integer(), String.t()}]
  def failures do
    for({number, id, failure} <- @beats, failure, do: {failure, number, id})
    |> Enum.sort_by(fn {"F" <> n, _number, _id} -> String.to_integer(n) end)
  end

  @doc """
  The record each beat shows, from the tour's reads: a map of beat number to a root, or
  `nil` when the beat has nothing to show yet.
  """
  @spec records(map()) :: %{pos_integer() => root() | nil}
  def records(
        %{activations: activations, readings: readings, cases: cases, release: release} = data
      ) do
    budget = Map.get(data, :budget, 0)

    %{
      1 => first_invocation(activations, fn _row -> true end),
      2 =>
        first_invocation(activations, &(&1.invocation.status in [:awaiting_approval, :succeeded])),
      3 => first_invocation(activations, &stale?(&1, "subject_changed")),
      4 => first_invocation(activations, &(&1.invocation.status == :failed)),
      5 =>
        first_invocation(
          activations,
          &(&1.invocation.status in [:executing, :outcome_unknown] or
              not is_nil(&1.invocation.reconciled_via))
        ),
      6 => first_run(readings, &(&1.findings != [])),
      7 => first_run(readings, fn r -> Enum.any?(r.model_calls, &(&1.outcome != :ok)) end),
      8 =>
        first_run(
          readings,
          &(&1.run.blocked_on == :budget or (&1.run.budget_limit || 0) > budget)
        ),
      9 => first_run(readings, & &1.erased?),
      10 => first_case(cases, fn _row -> true end),
      11 => first_case(cases, fn row -> Enum.any?(row.checks, &(&1.status == :failed)) end),
      12 => first_case(cases, &(&1.deliveries != [])),
      13 => first_case(cases, &(&1.review != nil)),
      14 => first_case(cases, &(&1.timer != nil)),
      15 => first_invocation(activations, &(&1.invocation.status == :awaiting_approval)),
      16 => candidate_run(release),
      17 => routed_case(release),
      18 => shadow_run(release),
      19 => first_invocation(activations, &stale?(&1, "manifest_changed"))
    }
  end

  @doc "The explorer path for `root`."
  @spec explorer_path(root()) :: String.t()
  def explorer_path({type, id}), do: ~p"/app/explorer?#{[root: "#{type}:#{id}"]}"

  defp stale?(row, code),
    do: row.invocation.status == :stale and row.invocation.error_code == code

  defp first_invocation(rows, keep?) do
    case Enum.find(rows, keep?) do
      %{invocation: %{id: id}} -> {:invocation, id}
      nil -> nil
    end
  end

  defp first_run(rows, keep?) do
    case Enum.find(rows, keep?) do
      %{run: %{id: id}} -> {:run, id}
      nil -> nil
    end
  end

  defp first_case(rows, keep?) do
    case Enum.find(rows, &(&1.instance && keep?.(&1))) do
      %{instance: %{id: id}} -> {:process_instance, id}
      nil -> nil
    end
  end

  # A suite run is not itself in the explorer; the agent runs its cases made are.
  defp candidate_run(%{candidate: %{case_runs: [id | _]}}), do: {:run, id}
  defp candidate_run(_release), do: nil

  defp shadow_run(%{shadow: [%{case_runs: [id | _]} | _]}), do: {:run, id}
  defp shadow_run(_release), do: nil

  # The case on the newest table version: the one that shows the table moved under the other.
  defp routed_case(%{routing: %{cases: [_ | _] = cases}}) do
    case Enum.max_by(cases, &(&1.table_version || 0), fn -> nil end) do
      %{id: id} -> {:process_instance, id}
      nil -> nil
    end
  end

  defp routed_case(_release), do: nil

  # --- components ---------------------------------------------------------------------

  attr :records, :map, required: true

  @doc "The F1–F12 index: each failure, its beat, and its record in the explorer."
  def index(assigns) do
    assigns = assign(assigns, failures: failures())

    ~H"""
    <section id="tour-index" aria-labelledby="tour-index-title" class="space-y-2">
      <h2 id="tour-index-title" class="font-heading text-lg">
        {dgettext("showcase", "The twelve failures")}
      </h2>
      <p class="text-sm text-foreground/70">
        {dgettext(
          "showcase",
          "Each failure the tour shows, the beat that shows it, and its record in the execution explorer."
        )}
      </p>
      <table class="w-full text-left text-sm">
        <thead>
          <tr class="border-b-2 border-border">
            <th class="py-1 pr-3">{dgettext("showcase", "Failure")}</th>
            <th class="py-1 pr-3">{dgettext("showcase", "What goes wrong")}</th>
            <th class="py-1 pr-3">{dgettext("showcase", "Beat")}</th>
            <th class="py-1 pr-3">{dgettext("showcase", "Record")}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={{failure, number, id} <- @failures}
            id={"index-#{failure}"}
            data-beat={number}
            data-recorded={to_string(@records[number] != nil)}
            class="border-b border-border/30 align-top"
          >
            <td class="py-1 pr-3 font-mono">{failure}</td>
            <td class="py-1 pr-3">{failure_label(failure)}</td>
            <td class="py-1 pr-3">
              <a id={"index-#{failure}-beat"} href={"##{id}"} class="underline">
                {dgettext("showcase", "Beat %{number}", number: number)}
              </a>
            </td>
            <td class="py-1 pr-3">
              <.link
                :if={@records[number]}
                id={"index-#{failure}-explore"}
                navigate={explorer_path(@records[number])}
                class="underline"
              >
                {dgettext("showcase", "Open in explorer")}
              </.link>
              <span
                :if={is_nil(@records[number])}
                id={"index-#{failure}-none"}
                class="text-foreground/60"
              >
                {dgettext("showcase", "No record yet")}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  attr :beat, :integer, required: true
  attr :records, :map, required: true

  @doc "A beat's \"open in explorer\" link to the record it shows, or that it has none yet."
  def explore(assigns) do
    assigns = assign(assigns, root: assigns.records[assigns.beat])

    ~H"""
    <p class="text-sm">
      <.link
        :if={@root}
        id={"explore-#{@beat}"}
        navigate={explorer_path(@root)}
        data-root={"#{elem(@root, 0)}:#{elem(@root, 1)}"}
        class="underline"
      >
        {dgettext("showcase", "Open in explorer")}
      </.link>
      <span :if={is_nil(@root)} id={"explore-#{@beat}-none"} class="text-foreground/60">
        {dgettext("showcase", "Nothing to open in the explorer yet.")}
      </span>
    </p>
    """
  end

  attr :fault_controls?, :boolean, required: true
  attr :recorded?, :boolean, required: true

  @doc """
  On a beat that needs a fault control, with the fault panel off: the demo-build note when
  the beat has no record, and when it has one, that the record below was made beforehand.
  """
  def fault_note(assigns) do
    ~H"""
    <p
      :if={not @fault_controls? and @recorded?}
      class="history-note text-sm italic text-foreground/70"
    >
      {dgettext(
        "showcase",
        "The fault panel is off here. The record below was made beforehand, by the demo's history (mix ash_enterprise.demo --history), through the same actions the panel uses."
      )}
    </p>
    <AshEnterpriseWeb.ShowcaseLive.CaseBeats.demo_build_note
      :if={not @recorded?}
      fault_controls?={@fault_controls?}
    />
    """
  end

  defp failure_label("F1"), do: dgettext("showcase", "The model times out mid-run")
  defp failure_label("F2"), do: dgettext("showcase", "The registry's answer is lost")
  defp failure_label("F3"), do: dgettext("showcase", "A deploy changes the approved tool")
  defp failure_label("F4"), do: dgettext("showcase", "The record changes during approval")
  defp failure_label("F5"), do: dgettext("showcase", "The requester's grant is revoked")
  defp failure_label("F6"), do: dgettext("showcase", "A webhook arrives twice, or early")
  defp failure_label("F7"), do: dgettext("showcase", "One parallel check is refused")
  defp failure_label("F8"), do: dgettext("showcase", "The token budget runs out")
  defp failure_label("F9"), do: dgettext("showcase", "A candidate fails its injection case")
  defp failure_label("F10"), do: dgettext("showcase", "A routing table changes under a case")
  defp failure_label("F11"), do: dgettext("showcase", "A person asks to be erased")
  defp failure_label("F12"), do: dgettext("showcase", "A shadow rerun must touch nothing")
end
