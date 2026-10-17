defmodule AshEnterpriseWeb.AssistantLive do
  @moduledoc """
  `/app/agent` — ask the in-zone assistant about your own day
  (`AshEnterprise.Assistant`).

  A conversation streams in place: the question is recorded, the in-zone
  model is asked with the read tools, each lookup appears inline as it
  happens (collapsed: the tool, its arguments, how many rows), and the
  answer's citations link to the records' own surfaces. Stop ends the run at
  the next chunk; a failed answer says why and offers Retry. History is per
  person and owner-only: `/app/agent/<id>` opens one of *your* threads, and
  anybody else's id is "not found".

  ## Zero jank

  The LiveView coordinates and never waits on the model: the run is
  `AshEnterprise.Assistant.Runner` under `AshEnterprise.TaskSupervisor`,
  sending events to this process. Reads (the thread, its turns, the thread
  list) run in `start_async`; mount does no query.

  ## When the in-zone model is down or slow

  Nothing goes anywhere else. A run that has heard nothing for
  #{20} seconds says the model is slow and keeps the Stop button; at
  #{300} seconds the page stops it. A refused or failed run records the
  answer as failed with its reason, which the page explains.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.AI.Models
  alias AshEnterprise.Assistant.{Answer, History, Runner, Thread, Turn}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.Layouts

  @slow_after_s 20
  @give_up_after_s 300
  @force_stop_ms 3_000

  @suggestions [
    "What's on my calendar tomorrow, and who's attending?",
    "Which email threads still need a reply from me?",
    "Who did I exchange the most messages with this month?",
    "What approvals are waiting on me?"
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:thread, nil)
     |> assign(:threads, [])
     |> assign(:empty?, true)
     |> assign(:run, nil)
     |> assign(:notice, nil)
     |> assign(:model, model_status())
     |> assign(:suggestions, @suggestions)
     |> assign(:max_steps, Runner.max_steps())
     |> assign(:form, to_form(%{"question" => ""}, as: :ask))
     |> stream_configure(:turns, dom_id: &"turn-#{&1.turn.id}")
     |> stream(:turns, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = if connected?(socket), do: load_threads(socket), else: socket

    case params["id"] do
      nil ->
        {:noreply,
         socket
         |> assign(thread: nil, empty?: true)
         |> stream(:turns, [], reset: true)}

      id ->
        if socket.assigns.thread && socket.assigns.thread.id == id do
          {:noreply, socket}
        else
          {:noreply, load_thread(socket, id)}
        end
    end
  end

  # -- asking ---------------------------------------------------------------------

  @impl true
  def handle_event("ask", %{"ask" => %{"question" => question}}, socket),
    do: {:noreply, ask(socket, String.trim(question))}

  def handle_event("suggest", %{"question" => question}, socket),
    do: {:noreply, ask(socket, question)}

  def handle_event("stop", _params, %{assigns: %{run: %{} = run}} = socket) do
    send(run.pid, {:assistant_stop, run.ref})
    Process.send_after(self(), {:force_stop, run.ref}, @force_stop_ms)
    {:noreply, assign(socket, :run, %{run | stopping?: true})}
  end

  def handle_event("stop", _params, socket), do: {:noreply, socket}

  def handle_event("retry", %{"question" => question_id}, %{assigns: %{run: nil}} = socket) do
    {:noreply, retry(socket, question_id)}
  end

  def handle_event("retry", _params, socket), do: {:noreply, socket}

  defp ask(socket, ""), do: socket
  defp ask(%{assigns: %{run: %{}}} = socket, _question), do: socket

  defp ask(%{assigns: %{thread: nil}} = socket, question) do
    case Thread.start(title(question), actor_opts(socket)) do
      {:ok, thread} ->
        socket
        |> assign(thread: thread, empty?: false)
        |> stream(:turns, [], reset: true)
        |> push_patch(to: ~p"/app/agent/#{thread.id}")
        |> start_run(question: question)

      {:error, _error} ->
        assign(socket, :notice, {:error, "Could not start a conversation. Try again."})
    end
  end

  defp ask(socket, question), do: start_run(socket, question: question)

  defp retry(socket, question_id) do
    with %Thread{} = thread <- socket.assigns.thread,
         {:ok, %{turns: entries}} <- History.load(thread.id, actor_opts(socket)),
         %{turn: %Turn{role: :user} = question} <-
           Enum.find(entries, &(&1.turn.id == question_id)) do
      start_run(socket, retry: question)
    else
      _ -> assign(socket, :notice, {:error, "That question is no longer here to retry."})
    end
  end

  defp start_run(socket, input) do
    ref = make_ref()
    answer_id = Ash.UUID.generate()
    actor = socket.assigns.current_user

    opts =
      input ++
        [
          thread: socket.assigns.thread,
          actor: actor,
          tenant: ActorContext.tenant(actor),
          notify: self(),
          ref: ref,
          answer_id: answer_id
        ]

    case Runner.start(opts) do
      {:ok, pid} ->
        Process.send_after(self(), {:tick, ref}, 1_000)

        socket
        |> assign(:notice, nil)
        |> assign(:form, to_form(%{"question" => ""}, as: :ask))
        |> assign(:run, %{
          ref: ref,
          pid: pid,
          answer_id: answer_id,
          question_id: input[:retry] && input[:retry].id,
          text: "",
          calls: [],
          step: 1,
          phase: :waiting,
          started: System.monotonic_time(:second),
          heard: System.monotonic_time(:second),
          elapsed: 0,
          slow?: false,
          stopping?: false
        })

      {:error, _} ->
        assign(socket, :notice, {:error, "Could not start the assistant. Try again."})
    end
  end

  # -- the run's events -------------------------------------------------------------

  @impl true
  def handle_info({:assistant, ref, event}, %{assigns: %{run: %{ref: ref} = run}} = socket) do
    run = %{run | heard: System.monotonic_time(:second), slow?: false}
    {:noreply, on_event(event, assign(socket, :run, run))}
  end

  # A late event from a run this page already gave up on.
  def handle_info({:assistant, _ref, _event}, socket), do: {:noreply, socket}

  def handle_info({:tick, ref}, %{assigns: %{run: %{ref: ref} = run}} = socket) do
    now = System.monotonic_time(:second)
    run = %{run | elapsed: now - run.started, slow?: now - run.heard >= @slow_after_s}

    if run.elapsed >= @give_up_after_s do
      {:noreply, give_up(assign(socket, :run, run), :timeout)}
    else
      Process.send_after(self(), {:tick, ref}, 1_000)
      {:noreply, assign(socket, :run, run)}
    end
  end

  def handle_info({:tick, _ref}, socket), do: {:noreply, socket}

  def handle_info({:force_stop, ref}, %{assigns: %{run: %{ref: ref}}} = socket),
    do: {:noreply, give_up(socket, :stopped)}

  def handle_info({:force_stop, _ref}, socket), do: {:noreply, socket}

  defp on_event({:user_turn, turn}, socket) do
    socket
    |> assign(:empty?, false)
    |> update_run(&%{&1 | question_id: turn.id})
    |> stream_insert(:turns, entry(turn))
  end

  defp on_event(:waiting, socket), do: update_run(socket, &%{&1 | phase: :waiting})

  defp on_event({:step, n}, socket), do: update_run(socket, &%{&1 | step: n})

  defp on_event({:text, chunk}, socket),
    do: update_run(socket, &%{&1 | text: &1.text <> chunk, phase: :streaming})

  defp on_event({:tool_call, call}, socket) do
    call = %{id: call.id, name: call.name, arguments: call.arguments, ok?: nil, count: nil}
    update_run(socket, &%{&1 | calls: &1.calls ++ [call], text: "", phase: :tool})
  end

  defp on_event({:tool_result, %{id: id, ok?: ok?, count: count}}, socket) do
    update_run(socket, fn run ->
      calls =
        Enum.map(run.calls, fn
          %{id: ^id} = call -> %{call | ok?: ok?, count: count}
          call -> call
        end)

      %{run | calls: calls}
    end)
  end

  defp on_event({:done, turn}, socket), do: settle(socket, turn, nil)
  defp on_event({:failed, reason, turn}, socket), do: settle(socket, turn, reason)
  defp on_event(_other, socket), do: socket

  defp update_run(socket, fun), do: assign(socket, :run, fun.(socket.assigns.run))

  defp settle(socket, turn, reason) do
    question_id = socket.assigns.run.question_id

    socket =
      socket
      |> assign(:run, nil)
      |> load_threads()

    socket =
      case turn do
        %Turn{} -> stream_insert(socket, :turns, entry(turn, question_id))
        nil -> socket
      end

    if reason && is_nil(turn),
      do: assign(socket, :notice, {:error, reason_message(reason)}),
      else: socket
  end

  # The page stops waiting: the run is ended, and the answer recorded from
  # what the page saw — under the run's own answer id, so a run that did
  # manage to record it first wins and this write is refused as a duplicate.
  defp give_up(%{assigns: %{run: run}} = socket, why) do
    _ = Task.Supervisor.terminate_child(AshEnterprise.TaskSupervisor, run.pid)
    opts = actor_opts(socket)
    thread = socket.assigns.thread

    attrs = %{
      id: run.answer_id,
      thread_id: thread.id,
      role: :assistant,
      content: String.trim(run.text),
      status: if(why == :stopped, do: :stopped, else: :failed),
      error_class: if(why == :stopped, do: nil, else: Atom.to_string(why)),
      tool_calls: %{
        "calls" =>
          Enum.map(
            run.calls,
            &%{
              "name" => &1.name,
              "arguments" => &1.arguments,
              "count" => &1.count,
              "ok" => &1.ok?
            }
          )
      },
      duration_ms: run.elapsed * 1000
    }

    socket
    |> assign(:run, nil)
    |> start_async(:give_up, fn ->
      _ = Turn.append(attrs, opts)
      History.load(thread.id, opts)
    end)
  end

  @impl true
  def handle_async(:threads, {:ok, threads}, socket),
    do: {:noreply, assign(socket, :threads, threads)}

  def handle_async(:threads, _failed, socket), do: {:noreply, socket}

  def handle_async(:thread, {:ok, {:ok, %{thread: thread, turns: entries}}}, socket) do
    {:noreply,
     socket
     |> assign(thread: thread, empty?: entries == [])
     |> stream(:turns, with_questions(entries), reset: true)}
  end

  def handle_async(:thread, _not_found, socket) do
    {:noreply,
     socket
     |> assign(:notice, {:error, "That conversation was not found, or is not yours."})
     |> push_patch(to: ~p"/app/agent")}
  end

  def handle_async(:give_up, {:ok, {:ok, %{turns: entries}}}, socket) do
    {:noreply, stream(socket, :turns, with_questions(entries), reset: true)}
  end

  def handle_async(:give_up, _result, socket), do: {:noreply, socket}

  # -- loading ----------------------------------------------------------------------

  defp load_threads(socket) do
    opts = actor_opts(socket)
    start_async(socket, :threads, fn -> History.threads(opts) end)
  end

  defp load_thread(socket, id) do
    opts = actor_opts(socket)

    socket
    |> assign(:thread, %Thread{id: id})
    |> stream(:turns, [], reset: true)
    |> start_async(:thread, fn -> History.load(id, opts) end)
  end

  defp entry(%Turn{} = turn, question_id \\ nil),
    do: %{turn: turn, withheld?: false, question_id: question_id}

  # Each answer carries the question it answered, for Retry.
  defp with_questions(entries) do
    {entries, _} =
      Enum.map_reduce(entries, nil, fn %{turn: turn} = entry, question ->
        case turn.role do
          :user -> {Map.put(entry, :question_id, nil), turn.id}
          :assistant -> {Map.put(entry, :question_id, question), question}
        end
      end)

    entries
  end

  defp actor_opts(socket) do
    actor = socket.assigns.current_user
    [actor: actor, tenant: ActorContext.tenant(actor), authorize?: true]
  end

  defp title(question) do
    if String.length(question) > 80, do: String.slice(question, 0, 79) <> "…", else: question
  end

  # What the header says about the model: configuration only, no call.
  defp model_status do
    target = Models.resolve(Models.default_spec())

    case target.residency do
      :in_zone -> {:in_zone, target.label |> String.replace_prefix("openai:", "")}
      :outside_zone -> :not_configured
    end
  end

  # -- rendering ----------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-7xl">
      <div class="grid gap-6 lg:grid-cols-[16rem_minmax(0,1fr)]">
        <aside class="flex flex-col gap-3" aria-label="Conversations">
          <.button id="new-chat" patch={~p"/app/agent"} variant="primary" size="sm" class="w-full">
            <.icon name="hero-plus" class="size-4" /> New conversation
          </.button>
          <nav id="threads" class="flex flex-col gap-1.5">
            <.link
              :for={thread <- @threads}
              id={"thread-#{thread.id}"}
              patch={~p"/app/agent/#{thread.id}"}
              class={[
                "truncate rounded-base border-2 px-3 py-2 text-sm transition-all",
                if(@thread && @thread.id == thread.id,
                  do: "border-border bg-secondary-background shadow-shadow",
                  else: "border-transparent hover:border-border hover:bg-secondary-background"
                )
              ]}
            >
              {thread_title(thread)}
            </.link>
            <p :if={@threads == []} class="px-3 text-xs text-foreground/60">
              Your conversations appear here. Only you can see them.
            </p>
          </nav>
        </aside>

        <section class="flex min-h-[60vh] flex-col gap-4">
          <.model_line model={@model} />

          <.callout :if={@notice} id="assistant-notice" kind={elem(@notice, 0)} role="alert">
            {elem(@notice, 1)}
          </.callout>

          <div :if={@empty? and is_nil(@run)} id="assistant-empty" class="flex flex-col gap-3">
            <.empty_state icon="hero-sparkles">
              Ask about your calendar, email, Slack, people, tasks and approvals.
              Answers link to the records they came from.
            </.empty_state>
            <div class="flex flex-wrap gap-2">
              <.button
                :for={{question, i} <- Enum.with_index(@suggestions)}
                id={"suggestion-#{i}"}
                type="button"
                size="sm"
                phx-click="suggest"
                phx-value-question={question}
                disabled={@model == :not_configured}
              >
                {question}
              </.button>
            </div>
          </div>

          <ol id="turns" phx-update="stream" class="flex flex-col gap-4">
            <li :for={{dom_id, entry} <- @streams.turns} id={dom_id}>
              <.turn entry={entry} running?={not is_nil(@run)} />
            </li>
          </ol>

          <.live_turn :if={@run} run={@run} max_steps={@max_steps} />

          <.form
            for={@form}
            id="ask-form"
            phx-submit="ask"
            class="sticky bottom-0 mt-auto flex items-end gap-2 border-t-2 border-border bg-background pt-3"
          >
            <textarea
              id="ask-question"
              name={@form[:question].name}
              rows="2"
              phx-hook=".SubmitOnEnter"
              placeholder={
                if @model == :not_configured,
                  do: "The in-zone model is not configured",
                  else: "Ask about your day… (Enter to send, Shift+Enter for a new line)"
              }
              disabled={@model == :not_configured}
              class="min-h-12 w-full resize-y rounded-base border-2 border-border bg-secondary-background px-3 py-2 text-sm shadow-shadow focus:outline-hidden focus-visible:ring-2 focus-visible:ring-ring"
            >{@form[:question].value}</textarea>
            <.button
              :if={is_nil(@run)}
              id="ask-send"
              type="submit"
              variant="primary"
              disabled={@model == :not_configured}
            >
              <.icon name="hero-paper-airplane" class="size-4" /> Ask
            </.button>
            <.button
              :if={@run}
              id="ask-stop"
              type="button"
              phx-click="stop"
              disabled={@run.stopping?}
            >
              <.icon name="hero-stop" class="size-4" /> {if @run.stopping?,
                do: "Stopping…",
                else: "Stop"}
            </.button>
          </.form>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
            export default {
              mounted() {
                this.el.addEventListener("keydown", e => {
                  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                    e.preventDefault()
                    this.el.form.requestSubmit()
                  }
                })
              }
            }
          </script>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :model, :any, required: true

  defp model_line(%{model: :not_configured} = assigns) do
    ~H"""
    <.callout id="model-status" kind={:warning} role="status">
      The in-zone model is not configured (<code>S1_GEN_BASE_URL</code>
      and <code>S1_GEN_MODEL</code>). The assistant uses only the in-zone model and
      never falls back to a hosted one, so it cannot answer until it is.
    </.callout>
    """
  end

  defp model_line(assigns) do
    ~H"""
    <p id="model-status" class="flex items-center gap-2 text-xs text-foreground/70">
      <.icon name="hero-shield-check" class="size-4" /> In-zone model
      <code class="font-mono">{elem(@model, 1)}</code>
      · reads only what you can read · nothing leaves the zone
    </p>
    """
  end

  attr :entry, :map, required: true
  attr :running?, :boolean, default: false

  defp turn(%{entry: %{turn: %{role: :user}}} = assigns) do
    ~H"""
    <div class="flex justify-end">
      <div class="max-w-[85%] whitespace-pre-wrap rounded-base border-2 border-border bg-main px-4 py-2 text-sm text-main-foreground shadow-shadow">
        {text(@entry.turn.content)}
      </div>
    </div>
    """
  end

  defp turn(%{entry: %{withheld?: true}} = assigns) do
    ~H"""
    <.callout kind={:info} class="max-w-[85%]">
      This answer drew on content that has since been erased, so it is no longer shown.
    </.callout>
    """
  end

  defp turn(assigns) do
    assigns =
      assign(assigns, :answer, Answer.parse(assigns.entry.turn.content, assigns.entry.turn.refs))

    ~H"""
    <article class="flex max-w-[92%] flex-col gap-3 rounded-base border-2 border-border bg-secondary-background px-4 py-3 shadow-shadow">
      <.tool_calls calls={calls(@entry.turn)} />
      <.answer_body :if={@answer.blocks != []} answer={@answer} />
      <.callout :if={@entry.turn.status == :failed} kind={:error} class="shadow-none">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <span>{reason_message(@entry.turn.error_class)}</span>
          <.button
            :if={@entry.question_id && not @running?}
            type="button"
            size="sm"
            phx-click="retry"
            phx-value-question={@entry.question_id}
          >
            <.icon name="hero-arrow-path" class="size-4" /> Retry
          </.button>
        </div>
      </.callout>
      <p
        :if={@entry.turn.status == :stopped}
        class="flex items-center gap-3 text-xs text-foreground/60"
      >
        Stopped.
        <.button
          :if={@entry.question_id && not @running?}
          type="button"
          size="xs"
          variant="ghost"
          phx-click="retry"
          phx-value-question={@entry.question_id}
        >
          <.icon name="hero-arrow-path" class="size-3.5" /> Retry
        </.button>
      </p>
    </article>
    """
  end

  attr :run, :map, required: true
  attr :max_steps, :integer, required: true

  defp live_turn(assigns) do
    ~H"""
    <article
      id="live-turn"
      class="flex max-w-[92%] flex-col gap-3 rounded-base border-2 border-border bg-secondary-background px-4 py-3 shadow-shadow"
      aria-live="polite"
    >
      <.tool_calls calls={Enum.map(@run.calls, &live_call/1)} />
      <p :if={@run.text != ""} class="whitespace-pre-wrap text-sm">
        {@run.text}<span class="animate-pulse">▍</span>
      </p>
      <p id="run-status" class="flex items-center gap-2 text-xs text-foreground/70">
        <.icon name="hero-arrow-path" class="size-4 animate-spin" />
        {phase_label(@run)} · step {@run.step} of {@max_steps} · {@run.elapsed}s
      </p>
      <.callout :if={@run.slow?} id="run-slow" kind={:warning} class="shadow-none" role="status">
        The in-zone model has not answered for a while — it may be busy, warming up or
        unreachable. Nothing is sent anywhere else. Keep waiting, or Stop.
      </.callout>
    </article>
    """
  end

  attr :calls, :list, required: true

  defp tool_calls(assigns) do
    ~H"""
    <div :if={@calls != []} class="flex flex-col gap-1.5">
      <details
        :for={call <- @calls}
        class="group rounded-base border-2 border-border bg-background text-xs"
      >
        <summary class="flex cursor-pointer list-none items-center gap-2 px-2.5 py-1.5 [&::-webkit-details-marker]:hidden">
          <.icon name="hero-magnifying-glass" class="size-3.5" />
          <span class="font-heading">{tool_label(call["name"])}</span>
          <span class="truncate text-foreground/60">{argument_line(call["arguments"])}</span>
          <span class="ms-auto">
            <.badge :if={call["ok"] == true} tone="green">{rows(call["count"])}</.badge>
            <.badge :if={call["ok"] == false} tone="red">error</.badge>
            <.badge :if={is_nil(call["ok"])}>…</.badge>
          </span>
          <.icon
            name="hero-chevron-down-micro"
            class="size-4 transition-transform group-open:rotate-180"
          />
        </summary>
        <pre class="overflow-x-auto border-t-2 border-border px-2.5 py-2 font-mono">{pretty(call["arguments"])}</pre>
      </details>
    </div>
    """
  end

  attr :answer, :map, required: true

  defp answer_body(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 text-sm leading-relaxed">
      <%= for block <- @answer.blocks do %>
        <%= case block do %>
          <% {:ul, items} -> %>
            <ul class="ms-5 list-disc space-y-1">
              <li :for={item <- items}><.tokens tokens={item} /></li>
            </ul>
          <% {:p, lines} -> %>
            <p>
              <%= for {line, i} <- Enum.with_index(lines) do %>
                <br :if={i > 0} /><.tokens tokens={line} />
              <% end %>
            </p>
        <% end %>
      <% end %>
      <div :if={@answer.sources != []} class="flex flex-wrap items-center gap-1.5 pt-1 text-xs">
        <span class="text-foreground/60">Sources</span>
        <.link
          :for={source <- @answer.sources}
          href={source.path}
          class="rounded-base border-2 border-border bg-background px-1.5 py-0.5 hover:bg-yellow"
        >
          {source.n} · {source.label}
        </.link>
      </div>
    </div>
    """
  end

  attr :tokens, :list, required: true

  defp tokens(assigns) do
    ~H"""
    <%= for token <- @tokens do %>
      <%= case token do %>
        <% {:text, text} -> %>
          {text}
        <% {:strong, text} -> %>
          <strong>{text}</strong>
        <% {:code, text} -> %>
          <code class="font-mono text-xs">{text}</code>
        <% {:cite, n, path} -> %>
          <.link
            href={path}
            class="ms-0.5 inline-grid min-w-5 place-items-center rounded-base border-2 border-border bg-yellow px-1 align-text-top text-[0.65rem] leading-4 text-on-vivid no-underline hover:shadow-shadow"
            title="Open the record"
          >{n}</.link>
      <% end %>
    <% end %>
    """
  end

  # -- small helpers -------------------------------------------------------------------

  defp calls(%Turn{tool_calls: %{"calls" => calls}}) when is_list(calls), do: calls
  defp calls(_turn), do: []

  defp live_call(call),
    do: %{
      "name" => call.name,
      "arguments" => call.arguments,
      "ok" => call.ok?,
      "count" => call.count
    }

  defp thread_title(%Thread{title: title}) when is_binary(title), do: title
  defp thread_title(_thread), do: "Conversation"

  defp text(content) when is_binary(content), do: content
  defp text(_shredded), do: "[erased]"

  defp tool_label(name) when is_binary(name),
    do: name |> String.replace("_", " ") |> String.capitalize()

  defp tool_label(_name), do: "Lookup"

  @doc false
  def argument_line(arguments) when is_map(arguments) do
    arguments
    |> unwrap()
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map_join(" · ", fn {key, value} -> "#{key}: #{scalar(value)}" end)
  end

  def argument_line(_arguments), do: ""

  # AshAi wraps a generic action's arguments in `input`.
  defp unwrap(%{"input" => %{} = input}), do: input
  defp unwrap(arguments), do: arguments

  defp scalar(value) when is_binary(value), do: value
  defp scalar(value), do: inspect(value)

  defp pretty(arguments) do
    shown =
      case unwrap(arguments) do
        %{} = map -> map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
        other -> other
      end

    case Jason.encode(shown, pretty: true) do
      {:ok, json} -> json
      _ -> ""
    end
  end

  defp rows(nil), do: "done"
  defp rows(1), do: "1 row"
  defp rows(n), do: "#{n} rows"

  defp phase_label(%{stopping?: true}), do: "Stopping"
  defp phase_label(%{phase: :tool}), do: "Looking it up"
  defp phase_label(%{phase: :streaming}), do: "Answering"
  defp phase_label(_run), do: "Asking the in-zone model"

  @doc "What the page says about a failed answer's reason."
  @spec reason_message(atom() | String.t() | nil) :: String.t()
  def reason_message(reason) when is_atom(reason) and not is_nil(reason),
    do: reason |> Atom.to_string() |> reason_message()

  def reason_message("not_configured"),
    do:
      "The in-zone model is not configured, so nothing was asked. The assistant never " <>
        "falls back to a hosted model."

  def reason_message("outside_zone"),
    do:
      "The configured model is outside the zone, so it was not asked. The assistant uses " <>
        "only the in-zone model."

  def reason_message("zone_mismatch"),
    do: "The in-zone model is not in the canonical store's zone, so it was not asked."

  def reason_message("model_unreachable"),
    do:
      "The in-zone model did not answer — its host may be down or off the network. " <>
        "Nothing was sent anywhere else. Try again shortly."

  def reason_message("model_recovering"),
    do:
      "The in-zone model is recovering and asked to be retried shortly. Nothing was sent anywhere else."

  def reason_message("model_error"),
    do: "The in-zone model returned an error. Try again, or rephrase."

  def reason_message("step_cap"),
    do:
      "Stopped after #{Runner.max_steps()} model calls without an answer. Try a narrower question."

  def reason_message("empty_answer"), do: "The model returned an empty answer. Try again."

  def reason_message("timeout"),
    do:
      "The in-zone model took longer than #{div(@give_up_after_s, 60)} minutes, so the page stopped waiting."

  def reason_message(_other), do: "Something went wrong answering this. Try again."
end
