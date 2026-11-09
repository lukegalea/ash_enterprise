defmodule AshEnterpriseWeb.ExplorerLive do
  @moduledoc """
  `/app/explorer`: one piece of work followed across its process, agent runs, decisions,
  approvals and invocations, as the trace (`AshEnterprise.Execution.Entry`'s `trace`)
  answers it for the signed-in person.

  A trace starts from a record's reference (`?root=invocation:<id>`, `run:`,
  `process_instance:`) or a correlation id (`?correlation_id=`). The page has three
  views of it and **one selection** (`?selected=<source ref>`), so each shows the same
  thing:

    * the **timeline**, every entry oldest first, as a list of buttons in a `log` live
      region: the view that needs no canvas, and the one a keyboard or a screen reader
      uses. An entry whose record exists but whose content is gone says so ("erased",
      "not recorded"); a source the trace could not read is an error row naming the
      source and why, never a gap;
    * the **diagram**, the BPMN of the process run in the trace with the selected
      entry's element highlighted (`AshBpmnViewer`). When it cannot be drawn the page
      says so and the timeline carries the selection alone;
    * the **detail** of the selected entry: its fields, the record behind it as the
      person may read it (`AshEnterprise.Execution.Explorer.detail/2`), the entry it
      belongs under and the entries under it, each selectable, and a trace of its
      correlation or its run.

  A long trace pages by cursor: "Load more" reads the next page of every source that
  has more (`AshEnterprise.Execution.Explorer.cursors/1`) and folds it in.

  Inspect only: the page reads what was recorded and never runs anything again. What a
  person did about a request (an `AshEnterprise.Execution.Intervention`: settled, rerun,
  cancelled, and why) is an entry under it, and a rerun sits under the request it reruns;
  stepping in is the recovery surface's (`/app/recovery/<id>`), which the detail links to
  when it offers something for the request. Everything is read as the signed-in person: what they may not read is not here.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Explorer
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.Layouts

  @root ~r/\A[a-z_]+:[0-9a-fA-F-]{36}\z/

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       trace: nil,
       entries: [],
       reports: [],
       error: nil,
       selected: nil,
       detail: nil,
       drawing: nil,
       nodes: %{},
       canvas_error: nil,
       recent: nil,
       recent_failed: [],
       form: to_form(%{"q" => ""}, as: :trace)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    trace = trace_args(params)

    socket =
      if trace == socket.assigns.trace and socket.assigns.recent != nil,
        do: socket,
        else: load(assign(socket, trace: trace))

    {:noreply, select(socket, params["selected"])}
  end

  @impl true
  def handle_event("trace", %{"trace" => %{"q" => q}}, socket) do
    q = String.trim(q)

    params =
      cond do
        q == "" -> %{}
        q =~ @root -> %{root: q}
        true -> %{correlation_id: q}
      end

    {:noreply, push_patch(socket, to: ~p"/app/explorer?#{params}")}
  end

  def handle_event("select", %{"ref" => ref}, socket) do
    {:noreply, push_patch(socket, to: explorer_path(socket.assigns.trace, ref))}
  end

  # The next page of every source that has more, read as the person, folded in.
  def handle_event("more", _params, socket) do
    %{trace: trace, reports: reports, entries: entries} = socket.assigns

    case Explorer.cursors(reports) do
      cursors when map_size(cursors) == 0 ->
        {:noreply, socket}

      cursors ->
        case Execution.trace(Map.put(trace, :cursors, cursors), opts(socket)) do
          {:ok, %{entries: page, sources: reports}} ->
            entries = Explorer.merge(entries, page)

            {:noreply,
             socket
             |> assign(entries: entries, reports: reports)
             |> assign(nodes: Explorer.nodes(entries, opts(socket)))}

          {:error, error} ->
            {:noreply, assign(socket, error: Exception.message(error))}
        end
    end
  end

  # The canvas reports that it could not draw the diagram.
  def handle_event("import_error", %{"message" => message}, socket),
    do: {:noreply, assign(socket, canvas_error: message)}

  defp trace_args(%{"root" => root}) when is_binary(root) and root != "", do: %{root_ref: root}

  defp trace_args(%{"correlation_id" => id}) when is_binary(id) and id != "",
    do: %{correlation_id: id}

  defp trace_args(_params), do: nil

  defp load(%{assigns: %{trace: nil}} = socket) do
    {recent, failed} = Explorer.recent(opts(socket))

    assign(socket,
      entries: [],
      reports: [],
      error: nil,
      drawing: nil,
      nodes: %{},
      canvas_error: nil,
      recent: recent,
      recent_failed: failed
    )
  end

  defp load(%{assigns: %{trace: trace}} = socket) do
    opts = opts(socket)

    case Execution.trace(trace, opts) do
      {:ok, %{entries: entries, sources: reports}} ->
        drawing =
          case Explorer.drawing(entries, opts) do
            {:ok, drawing} -> drawing
            :none -> nil
          end

        assign(socket,
          entries: entries,
          reports: reports,
          error: nil,
          drawing: drawing,
          nodes: Explorer.nodes(entries, opts),
          canvas_error: nil,
          recent: []
        )

      {:error, error} ->
        assign(socket,
          entries: [],
          reports: [],
          error: Exception.message(error),
          drawing: nil,
          nodes: %{},
          recent: []
        )
    end
  end

  # One selection for the three views: the detail reads the selected entry's record, and
  # the diagram highlights the element it happened on (none when it is not on it).
  defp select(socket, ref) do
    entry = ref && Enum.find(socket.assigns.entries, &(&1.source_ref == ref))

    detail =
      case entry && Explorer.detail(entry.source_ref, opts(socket)) do
        {:ok, detail} -> detail
        nil -> nil
        unreadable_or_none -> unreadable_or_none
      end

    node = entry && Map.get(socket.assigns.nodes, entry.source_ref)

    socket
    |> assign(selected: entry && entry.source_ref, detail: detail)
    |> push_event("highlight", %{node_ids: List.wrap(node)})
  end

  defp opts(socket) do
    actor = socket.assigns.current_user
    [actor: actor, tenant: ActorContext.tenant(actor)]
  end

  defp explorer_path(trace, selected) do
    params =
      case trace do
        %{root_ref: root} -> %{root: root}
        %{correlation_id: id} -> %{correlation_id: id}
        nil -> %{}
      end

    params = if selected, do: Map.put(params, :selected, selected), else: params
    ~p"/app/explorer?#{params}"
  end

  # --- render ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        by_ref: Map.new(assigns.entries, &{&1.source_ref, &1}),
        selected_entry: Enum.find(assigns.entries, &(&1.source_ref == assigns.selected)),
        more: Enum.filter(assigns.reports, &(&1.status == :more))
      )

    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-7xl">
      <.form
        for={@form}
        id="explorer-trace-form"
        phx-submit="trace"
        class="flex flex-wrap items-end gap-3"
      >
        <div class="min-w-72 flex-1">
          <.input
            field={@form[:q]}
            label={gettext("A record's reference or a correlation id")}
            placeholder="invocation:… / run:… / process_instance:…"
          />
        </div>
        <.button type="submit" variant="primary">{gettext("Trace")}</.button>
      </.form>

      <.status_message id="explorer-error" role="alert" kind={:error} show={@error != nil}>
        {gettext("The trace could not be read: %{reason}", reason: @error)}
      </.status_message>

      <section :if={@trace == nil} id="explorer-recent" class="mt-6 space-y-3">
        <h2 class="font-heading text-base">{gettext("Recent work you may read")}</h2>
        <p
          :if={@recent == [] and @recent_failed == []}
          id="explorer-recent-none"
          class="text-sm text-foreground/70"
        >
          {gettext("Nothing yet.")}
        </p>
        <.status_message
          id="explorer-recent-failed"
          role="alert"
          kind={:error}
          show={@recent_failed != []}
        >
          {gettext("Some recent work could not be read: %{kinds}. What is listed is not all of it.",
            kinds: Enum.map_join(@recent_failed, ", ", &type_label/1)
          )}
        </.status_message>
        <ul class="divide-y divide-border rounded-base border-2 border-border">
          <li :for={item <- @recent || []} id={"recent-" <> item.ref}>
            <.link
              patch={~p"/app/explorer?#{%{root: item.ref}}"}
              class="flex flex-wrap items-center gap-3 px-3 py-2 hover:bg-secondary-background focus-visible:outline-2"
              data-ref={item.ref}
            >
              <span class="font-base">{type_label(item.type)}</span>
              <span class="font-mono text-sm">{item.label}</span>
              <.badge status={item.status}>{item.status}</.badge>
              <.run_mode :if={item.type != "process_instance"} mode={item.mode} />
              <time class="text-xs text-foreground/70" datetime={DateTime.to_iso8601(item.at)}>
                {LocalTime.stamp_seconds(item.at)}
              </time>
            </.link>
          </li>
        </ul>
      </section>

      <div :if={@trace != nil} class="mt-6 grid gap-6 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <section id="explorer-timeline" aria-labelledby="timeline-title" class="space-y-3">
          <h2 id="timeline-title" class="font-heading text-base">
            {gettext("Timeline")}
            <span class="font-base text-sm text-foreground/70">
              {scope_label(@trace)}
            </span>
          </h2>
          <.timeline entries={@entries} selected={@selected} empty?={@error == nil} />
          <div :if={@more != []} id="timeline-paging" class="flex flex-wrap items-center gap-3">
            <.button id="timeline-more" phx-click="more" size="sm">
              {gettext("Load more")}
            </.button>
            <span class="text-sm text-foreground/70">
              {gettext("More to read from: %{sources}",
                sources: Enum.map_join(@more, ", ", &to_string(&1.source))
              )}
            </span>
          </div>
        </section>

        <div class="space-y-6">
          <.diagram
            drawing={@drawing}
            canvas_error={@canvas_error}
            node={@selected_entry && Map.get(@nodes, @selected_entry.source_ref)}
          />
          <.detail
            entry={@selected_entry}
            detail={@detail}
            entries={@entries}
            by_ref={@by_ref}
            trace={@trace}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc """
  The timeline: every entry, oldest first, each a button that selects it, in a `log` live
  region so what a later page adds is announced. An entry under another entry of the
  trace is indented under it. A source the trace could not read is an error row naming
  the source and why (its gap entry, `source:<name>`), never a missing row.
  """
  attr :entries, :list, required: true
  attr :selected, :string, default: nil
  attr :empty?, :boolean, default: true, doc: "say so when there are no entries"

  def timeline(assigns) do
    assigns = assign(assigns, :refs, MapSet.new(assigns.entries, & &1.source_ref))

    ~H"""
    <.live_region id="timeline" role="log" aria-labelledby="timeline-title">
      <p :if={@entries == [] and @empty?} id="timeline-empty" class="text-sm">
        {gettext("Nothing in this trace that you may read.")}
      </p>
      <ol class="space-y-1">
        <li :for={{entry, n} <- Enum.with_index(@entries)} id={"entry-#{n}"}>
          <.entry_row
            entry={entry}
            selected?={entry.source_ref == @selected}
            nested?={MapSet.member?(@refs, entry.parent_ref)}
          />
        </li>
      </ol>
    </.live_region>
    """
  end

  attr :entry, :map, required: true
  attr :selected?, :boolean, required: true
  attr :nested?, :boolean, default: false

  defp entry_row(%{entry: %{source_ref: "source:" <> _}} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select"
      phx-value-ref={@entry.source_ref}
      aria-current={@selected? && "true"}
      data-ref={@entry.source_ref}
      data-row="error"
      data-status={@entry.status}
      class={[
        "flex w-full flex-wrap items-center gap-2 rounded-base border-2 border-red px-3 py-2 text-left",
        @selected? && "bg-red/20"
      ]}
    >
      <.icon name="hero-exclamation-triangle" class="size-4" />
      <span class="font-base">
        {gettext("Could not read %{source}", source: @entry.source)}
      </span>
      <span class="text-sm">{@entry.summary}</span>
    </button>
    """
  end

  defp entry_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select"
      phx-value-ref={@entry.source_ref}
      aria-current={@selected? && "true"}
      data-ref={@entry.source_ref}
      data-row="entry"
      data-kind={@entry.kind}
      data-status={@entry.status}
      data-recorded={to_string(@entry.recorded?)}
      class={[
        "flex w-full flex-wrap items-center gap-2 rounded-base border-2 px-3 py-2 text-left hover:bg-secondary-background focus-visible:outline-2",
        if(@selected?, do: "border-border bg-main/20", else: "border-transparent"),
        @nested? && "ml-6 w-[calc(100%-1.5rem)]"
      ]}
    >
      <time class="font-mono text-xs text-foreground/70" datetime={DateTime.to_iso8601(@entry.at)}>
        {LocalTime.clock(@entry.at)}
      </time>
      <.badge tone={entry_tone(@entry.status)}>{status_label(@entry.status)}</.badge>
      <span class="text-xs uppercase tracking-wide text-foreground/70">
        {kind_label(@entry.kind)}
      </span>
      <span class="text-sm">{@entry.summary}</span>
      <span :if={@entry.blocked_on} class="text-xs">
        {gettext("on %{what}", what: @entry.blocked_on)}
      </span>
      <.badge :if={!@entry.recorded?} tone="neutral" data-not-recorded>
        {not_recorded_label(@entry)}
      </.badge>
    </button>
    """
  end

  attr :drawing, :map, default: nil
  attr :canvas_error, :string, default: nil
  attr :node, :string, default: nil

  defp diagram(assigns) do
    ~H"""
    <section id="explorer-diagram" aria-labelledby="diagram-title" class="space-y-2">
      <h2 id="diagram-title" class="font-heading text-base">{gettext("Diagram")}</h2>
      <p :if={@drawing == nil} id="diagram-none" class="text-sm text-foreground/70">
        {gettext("No process run you may read is in this trace.")}
      </p>
      <div :if={@drawing} class="space-y-2">
        <p class="text-sm text-foreground/70">
          {gettext("Process %{definition}", definition: @drawing.definition)}
        </p>
        <.callout :if={@canvas_error} id="diagram-unavailable" kind={:warning}>
          {gettext("The diagram cannot be drawn here. The timeline carries the same selection.")}
        </.callout>
        <%!-- A picture of the selection, which the line below and the timeline say in
        words: inert, so neither a screen reader nor the tab order lands in the canvas. --%>
        <div
          id={"explorer-bpmn-" <> @drawing.instance_id}
          class={["ash-bpmn-canvas-pane relative h-80 overflow-hidden", @canvas_error && "hidden"]}
          phx-hook="AshBpmnViewer"
          phx-update="ignore"
          data-xml={@drawing.xml}
          inert
        >
          <div class="ash-bpmn-canvas ash-bpmn-canvas-frame h-full"></div>
        </div>
        <p id="diagram-selection" data-node={@node} class="text-sm">
          <%= if @node do %>
            {gettext("Selected on the diagram: %{name}",
              name: Map.get(@drawing.names, @node, @node)
            )}
          <% else %>
            {gettext("The selected entry is not on the diagram.")}
          <% end %>
        </p>
      </div>
    </section>
    """
  end

  attr :entry, :map, default: nil
  attr :detail, :any, default: nil
  attr :entries, :list, required: true
  attr :by_ref, :map, required: true
  attr :trace, :map, required: true

  defp detail(%{entry: nil} = assigns) do
    ~H"""
    <section id="explorer-detail" aria-labelledby="detail-title" class="space-y-2">
      <h2 id="detail-title" class="font-heading text-base">{gettext("Detail")}</h2>
      <p id="detail-none" class="text-sm text-foreground/70">
        {gettext("Select an entry on the timeline.")}
      </p>
    </section>
    """
  end

  defp detail(assigns) do
    assigns =
      assign(assigns,
        parent: assigns.entry.parent_ref && Map.get(assigns.by_ref, assigns.entry.parent_ref),
        children: Enum.filter(assigns.entries, &(&1.parent_ref == assigns.entry.source_ref))
      )

    ~H"""
    <section
      id="explorer-detail"
      aria-labelledby="detail-title"
      data-ref={@entry.source_ref}
      class="space-y-3 rounded-base border-2 border-border p-4"
    >
      <h2 id="detail-title" class="font-heading text-base">
        {kind_label(@entry.kind)}: {@entry.summary}
      </h2>
      <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
        <dt>{gettext("Status")}</dt>
        <dd id="detail-status" data-status={@entry.status}>
          {status_label(@entry.status)}
          <span :if={@entry.blocked_on}>({gettext("on %{what}", what: @entry.blocked_on)})</span>
        </dd>
        <dt>{gettext("When")}</dt>
        <dd>{LocalTime.stamp_seconds(@entry.at)}</dd>
        <dt>{gettext("Record")}</dt>
        <dd class="font-mono break-all">{@entry.source_ref}</dd>
        <dt :if={@entry.definition_ref}>{gettext("Definition")}</dt>
        <dd :if={@entry.definition_ref} class="font-mono break-all">{@entry.definition_ref}</dd>
        <dt :if={@entry.actor_label}>{gettext("Ran as")}</dt>
        <dd :if={@entry.actor_label} class="font-mono break-all">{@entry.actor_label}</dd>
        <dt :if={@entry.cost}>{gettext("Cost")}</dt>
        <dd :if={@entry.cost}>{cost_label(@entry.cost)}</dd>
        <dt :if={!@entry.recorded?}>{gettext("Content")}</dt>
        <dd :if={!@entry.recorded?} id="detail-not-recorded">{not_recorded_label(@entry)}</dd>
      </dl>

      <.record detail={@detail} trace={@trace} />

      <div :if={@parent} id="detail-parent" class="text-sm">
        <span>{gettext("Under")}</span>
        <.select_button entry={@parent} />
      </div>
      <div :if={@children != []} id="detail-children" class="space-y-1 text-sm">
        <span>{gettext("Under it")}</span>
        <ul class="space-y-1">
          <li :for={child <- @children}><.select_button entry={child} /></li>
        </ul>
      </div>
    </section>
    """
  end

  attr :entry, :map, required: true

  defp select_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select"
      phx-value-ref={@entry.source_ref}
      data-ref={@entry.source_ref}
      class="underline underline-offset-2 hover:no-underline"
    >
      {kind_label(@entry.kind)}: {@entry.summary} ({status_label(@entry.status)})
    </button>
    """
  end

  attr :detail, :any, required: true
  attr :trace, :map, required: true

  defp record(%{detail: :failed} = assigns) do
    ~H"""
    <div id="detail-record" data-record="failed" class="text-sm">
      <.status_message id="detail-record-failed" role="alert" kind={:error}>
        {gettext("The record behind this entry could not be read. Try again.")}
      </.status_message>
    </div>
    """
  end

  defp record(%{detail: :unreadable} = assigns) do
    ~H"""
    <p id="detail-record" data-record="unreadable" class="text-sm">
      {gettext("You may not read the record behind this entry.")}
    </p>
    """
  end

  defp record(%{detail: %{}} = assigns) do
    assigns = assign(assigns, facts: facts(assigns.detail))

    ~H"""
    <div id="detail-record" data-record={@detail.type} class="space-y-2 text-sm">
      <.run_mode :if={Map.has_key?(@detail, :mode)} mode={@detail.mode} id="detail-run-mode" />
      <dl :if={@facts != []} class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
        <%= for {label, value} <- @facts do %>
          <dt>{label}</dt>
          <dd class="break-all">{value}</dd>
        <% end %>
      </dl>
      <.arguments :if={Map.has_key?(@detail, :args)} id="detail-args" args={@detail.args} />
      <div :if={@detail[:calls] not in [nil, []]} id="detail-calls" class="space-y-2">
        <h3 class="font-base">{gettext("Tool calls")}</h3>
        <p :if={@detail.calls == :failed} id="detail-calls-failed">
          {gettext("This turn's tool calls could not be read.")}
        </p>
        <div
          :for={call <- if(is_list(@detail.calls), do: @detail.calls, else: [])}
          id={"detail-call-" <> call.id}
          class="rounded-base border-2 border-border p-2"
        >
          <p>
            <span class="font-mono">{call.target}</span>
            <.badge status={call.status}>{call.status}</.badge>
          </p>
          <.arguments id={"detail-call-args-" <> call.id} args={call.args} />
        </div>
      </div>
      <div :if={@detail[:cited] not in [nil, []]} id="detail-evidence">
        <h3 class="font-base">{gettext("Evidence cited")}</h3>
        <ul class="font-mono text-xs">
          <li :for={atom <- @detail.cited}>{atom}</li>
        </ul>
      </div>
      <p :if={@detail[:correlation_id]} id="detail-correlation">
        <.link
          patch={~p"/app/explorer?#{%{correlation_id: @detail.correlation_id}}"}
          class="underline underline-offset-2"
        >
          {gettext("Trace everything recorded with it")}
        </.link>
      </p>
      <p :if={@detail[:run_id] && @detail.type in [:case_result, :step]} id="detail-run">
        <.link
          patch={
            ~p"/app/explorer?#{%{root: "run:" <> @detail.run_id, selected: "run:" <> @detail.run_id}}"
          }
          class="underline underline-offset-2"
        >
          {gettext("Open the run it graded or belongs to")}
        </.link>
      </p>
      <p :if={@detail[:rerun_of_id]} id="detail-rerun-of">
        <.link
          patch={
            ~p"/app/explorer?#{%{root: "invocation:" <> @detail.rerun_of_id, selected: "invocation:" <> @detail.rerun_of_id}}"
          }
          class="underline underline-offset-2"
        >
          {gettext("Open the request this reruns")}
        </.link>
      </p>
      <p :if={@detail[:rerun_id]} id="detail-rerun">
        <.link
          patch={
            ~p"/app/explorer?#{%{root: "invocation:" <> @detail.rerun_id, selected: "invocation:" <> @detail.rerun_id}}"
          }
          class="underline underline-offset-2"
        >
          {gettext("Open the request it asked for")}
        </.link>
      </p>
      <p :if={@detail[:recoverable?]} id="detail-recovery">
        <.link navigate={~p"/app/recovery/#{@detail.id}"} class="underline underline-offset-2">
          {gettext("Step in on this request (recovery)")}
        </.link>
      </p>
    </div>
    """
  end

  defp record(assigns), do: ~H""

  attr :id, :string, required: true
  attr :args, :any, required: true

  defp arguments(%{args: :erased} = assigns) do
    ~H"""
    <p id={@id} data-args="erased">{gettext("Arguments: erased")}</p>
    """
  end

  defp arguments(%{args: args} = assigns) when is_map(args) do
    ~H"""
    <dl id={@id} data-args="readable" class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
      <%= for {key, value} <- Enum.sort(@args) do %>
        <dt class="font-mono">{key}</dt>
        <dd :if={value == :sensitive} class="italic" data-sensitive>
          {gettext("sensitive, not shown")}
        </dd>
        <dd :if={value != :sensitive} class="font-mono break-all">{inspect(value)}</dd>
      <% end %>
    </dl>
    """
  end

  defp arguments(assigns) do
    ~H"""
    <p id={@id} data-args="none">{gettext("Arguments: none recorded")}</p>
    """
  end

  # --- labels ---------------------------------------------------------------------------

  defp facts(%{type: :run} = d),
    do:
      [
        {gettext("Agent"), d.agent_key},
        {gettext("Run status"), d.status},
        {gettext("Failure"), d.failure_class},
        {gettext("Error code"), d.error_code}
      ]
      |> present()

  defp facts(%{type: type} = d) when type in [:invocation, :effect],
    do:
      [
        {gettext("Target"), d.target},
        {gettext("Lifecycle status"), d.status},
        {gettext("Simulated"), d.simulated? && gettext("yes")},
        {gettext("Failure"), d.failure_class},
        {gettext("Error code"), d.error_code}
      ]
      |> present()

  defp facts(%{type: :step} = d),
    do:
      [
        {gettext("Turn"), d.seq},
        {gettext("Role"), d.role},
        {gettext("Tools called"), Enum.join(d.tools, ", ")},
        {gettext("Content"), if(d.recorded?, do: gettext("recorded"), else: gettext("erased"))}
      ]
      |> present()

  defp facts(%{type: :human_task} = d),
    do:
      [
        {gettext("Task"), d.name},
        {gettext("Task status"), d.status},
        {gettext("Outcome"), d.outcome},
        {gettext("Decided by"), d.decided_by_id && "person:#{d.decided_by_id}"}
      ]
      |> present()

  defp facts(%{type: :process_event} = d),
    do: present([{gettext("Event"), d.kind}, {gettext("Element"), d.node_id}])

  defp facts(%{type: :process_instance} = d),
    do: present([{gettext("Process status"), d.status}, {gettext("Outcome"), d.outcome}])

  defp facts(%{type: :evaluation} = d),
    do:
      [
        {gettext("Decision"), d.decision_id},
        {gettext("Table version"), d.definition},
        {gettext("Hit policy"), d.hit_policy},
        {gettext("Matched rules"),
         if(d.matched_rule_ids == [],
           do: gettext("no rule matched"),
           else: Enum.join(d.matched_rule_ids, ", ")
         )},
        {gettext("Error"), d.failed? && gettext("the evaluation recorded an error")}
      ]
      |> present()

  defp facts(%{type: :judgment} = d),
    do:
      [
        {gettext("Question"), d.question},
        {gettext("Answer"), d.answer_kind},
        {gettext("Subject"), d.subject},
        {gettext("Judged text"),
         if(d.recorded?, do: gettext("sealed in the ledger"), else: gettext("erased"))}
      ]
      |> present()

  defp facts(%{type: :intervention} = d),
    do:
      [
        {gettext("Act"), d.act},
        {gettext("Settled as"), d.resolution},
        {gettext("Reason given"), d.reason},
        {gettext("By"), d.owner_id && "person:#{d.owner_id}"}
      ]
      |> present()

  defp facts(%{type: :case_result} = d),
    do: present([{gettext("Case"), d.case_id}, {gettext("Result"), d.status}])

  defp facts(%{type: :model_call} = d),
    do:
      [
        {gettext("Profile"), d.profile},
        {gettext("Model"), d.model},
        {gettext("Outcome"), d.outcome},
        {gettext("Error class"), d.error_class},
        {gettext("Tokens"), d.tokens || gettext("not recorded")},
        {gettext("Duration (ms)"), d.duration_ms || gettext("not recorded")}
      ]
      |> present()

  defp facts(_detail), do: []

  defp present(facts),
    do: for({label, value} <- facts, value not in [nil, false, ""], do: {label, value})

  defp scope_label(%{root_ref: root}), do: gettext("from %{ref}", ref: root)
  defp scope_label(%{correlation_id: id}), do: gettext("correlation %{id}", id: id)

  defp type_label("invocation"), do: gettext("Invocation")
  defp type_label("run"), do: gettext("Agent run")
  defp type_label("process_instance"), do: gettext("Process run")

  defp kind_label(:logical_operation), do: gettext("Operation")
  defp kind_label(:attempt), do: gettext("Attempt")
  defp kind_label(:observation), do: gettext("Observation")
  defp kind_label(:decision), do: gettext("Decision")
  defp kind_label(:proposal), do: gettext("Proposal")
  defp kind_label(:approval), do: gettext("Approval")
  defp kind_label(:effect), do: gettext("Effect")
  defp kind_label(:model_call), do: gettext("Model call")
  defp kind_label(:process_event), do: gettext("Process event")
  defp kind_label(other), do: to_string(other)

  defp status_label(:waiting), do: gettext("Waiting")
  defp status_label(:running), do: gettext("Running")
  defp status_label(:succeeded), do: gettext("Succeeded")
  defp status_label(:failed), do: gettext("Failed")
  defp status_label(:cancelled), do: gettext("Cancelled")
  defp status_label(_uncertain), do: gettext("Uncertain")

  defp entry_tone(:waiting), do: "yellow"
  defp entry_tone(:running), do: "main"
  defp entry_tone(:succeeded), do: "green"
  defp entry_tone(:failed), do: "red"
  defp entry_tone(:cancelled), do: "neutral"
  defp entry_tone(_uncertain), do: "orange"

  # What a record that exists but holds nothing readable says: a model call whose
  # telemetry never arrived was not recorded; any other was erased.
  defp not_recorded_label(%{source: :model_call}), do: gettext("not recorded")
  defp not_recorded_label(_entry), do: gettext("erased")

  defp cost_label(cost) do
    [
      cost[:tokens] && gettext("%{n} tokens", n: cost[:tokens]),
      cost[:duration_ms] && gettext("%{n} ms", n: cost[:duration_ms])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end
end
