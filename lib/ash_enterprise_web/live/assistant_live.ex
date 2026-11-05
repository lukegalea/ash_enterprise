defmodule AshEnterpriseWeb.AssistantLive do
  @moduledoc """
  `/app/agent` — ask the in-zone assistant about your own day
  (`AshEnterprise.Assistant`).

  A conversation follows each answer in place: the question is recorded, a
  durable run of the assistant agent answers it (`AshEnterprise.Assistant.Ask`),
  each lookup appears inline as the run records it (collapsed: the tool, its
  arguments, how many rows), and the answer's citations link to the records'
  own surfaces. Stop cancels the run; a failed answer says why and offers
  Retry. History is per person and owner-only: `/app/agent/<id>` opens one of
  *your* threads, and anybody else's id is "not found".

  ## Zero jank

  The LiveView coordinates and never waits on the model: the answer is an
  `AshEnterprise.Execution.Run`, stepped by its jobs. The page subscribes to
  the run's updates (`Ask.topic/1`) and reads its journal again as the person
  on each one, in `start_async`, as it reads the thread, its turns and the
  thread list; mount does no query. Leaving the page loses nothing: opening
  the thread again records any answer that finished meanwhile and follows a
  run still working.

  ## Composed surfaces, inline

  When the model calls `compose_surface`, its result in the run's journal
  carries the verified request. The answer then carries a container
  for it (`InlineA2ui`, `assets/js/inline_a2ui_hook.js`), which asks for its
  surface once mounted; the page composes the request again **as the person**
  (`AshEnterprise.Assistant.Composer`), holds the resolved surface server-side
  under its id and pushes the A2UI messages to that container alone. Client
  actions are routed back to the held surface by its id — never rebuilt from
  anything the client sends. Pin saves the verified spec as a personal app
  (`AshEnterprise.Assistant.PinnedApp`), which lists under "My apps" on the
  launcher.

  ## Requests wait for the person

  A change the assistant asks for (add or finish an action item, draft a reply, sync
  an account, decide a task or a duplicate) is a governed invocation the run
  requested as the person (ADR 0055), awaiting their approval; the answer ends there
  (`AshEnterprise.Assistant.Ask`). The answer shows each request
  (`AshEnterprise.Assistant.Requests`) with what it would do and Confirm / Cancel.
  Confirm approves it as the person and runs it once, as them, under their grants
  as they are now; Cancel rejects it, and nothing runs. Either is the invocation's
  own state, so a second click from another tab finds it decided, and reopening the
  thread shows each request as it now stands. The page follows each open request on
  its own topic (`invocations:<id>`), so a decision made elsewhere shows here too.

  Answers recorded before 4 November 2026 proposed changes another way; they show
  what was proposed, as earlier, and offer nothing.

  ## When the in-zone model is down or slow

  Nothing goes anywhere else. A run that has moved on for #{20} seconds
  says the model is slow and keeps the Stop button. A step whose model call
  fails is tried again from the run's journal until the run's deadline
  (`AshEnterprise.Assistant.Agent`), which fails the answer. A refused or
  failed run records the answer as failed with its reason, which the page
  explains.

  ## Turning it on

  An organization with no published assistant gets `not_published`. An operator runs
  `mix ash_enterprise.assistant.enable --org <org> --as <administrator email>`, which
  requests the publish and prints the approval link; members then need its start grant.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.AI.Models

  alias AshEnterprise.Assistant.{
    Answer,
    Ask,
    Composer,
    History,
    PinnedApp,
    Requests,
    Thread,
    Turn
  }

  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2ui.Host
  alias AshEnterpriseWeb.AssistantHandoff
  alias AshEnterpriseWeb.Layouts

  @slow_after_s 20
  # A run's updates are pushed; every few seconds the page also looks, in case one
  # was missed.
  @poll_every_s 5

  @suggestions [
    "What's on my calendar tomorrow, and who's attending?",
    "Which email threads still need a reply from me?",
    "Who did I exchange the most messages with this month?",
    "Show my open tasks as a board",
    "Put this week's meetings on a calendar"
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
     |> assign(:max_steps, Ask.max_steps())
     |> assign(:form, to_form(%{"question" => ""}, as: :ask))
     # What the model put on the page, by the page's own id: composed
     # surfaces (their verified requests) and requests (as the person reads them,
     # with their state). `surfaces` holds each resolved surface server-side;
     # `requests` maps a followed invocation's id to its page id.
     |> assign(:shown, %{})
     |> assign(:surfaces, %{})
     |> assign(:requests, %{})
     |> assign(:answers, %{})
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
         |> stream(:turns, [], reset: true)
         |> handoff(params["ask"])}

      id ->
        if socket.assigns.thread && socket.assigns.thread.id == id do
          {:noreply, socket}
        else
          {:noreply, load_thread(socket, id)}
        end
    end
  end

  # A question the Helper handed over (`AshEnterpriseWeb.AssistantHandoff`):
  # asked once the page is connected, only for the person it was handed by.
  defp handoff(socket, token) when is_binary(token) do
    if connected?(socket),
      do: ask_handed(socket, AssistantHandoff.question(socket.assigns.current_user, token)),
      else: socket
  end

  defp handoff(socket, _no_token), do: socket

  defp ask_handed(socket, {:ok, question}), do: ask(socket, String.trim(question))

  defp ask_handed(socket, :error),
    do: assign(socket, :notice, {:error, "That question has expired. Ask it again here."})

  # -- asking ---------------------------------------------------------------------

  @impl true
  def handle_event("ask", %{"ask" => %{"question" => question}}, socket),
    do: {:noreply, ask(socket, String.trim(question))}

  def handle_event("suggest", %{"question" => question}, socket),
    do: {:noreply, ask(socket, question)}

  def handle_event("stop", _params, %{assigns: %{run: %{} = run}} = socket) do
    opts = actor_opts(socket)
    thread = socket.assigns.thread

    {:noreply,
     socket
     |> assign(:run, %{run | stopping?: true})
     |> start_async({:run, run.id}, fn ->
       _ = Ask.stop(run.id, opts)
       follow(thread, run.id, opts)
     end)}
  end

  def handle_event("stop", _params, socket), do: {:noreply, socket}

  def handle_event("retry", %{"question" => question_id}, %{assigns: %{run: nil}} = socket) do
    {:noreply, retry(socket, question_id)}
  end

  def handle_event("retry", _params, socket), do: {:noreply, socket}

  # -- what an answer put on the page ----------------------------------------------

  # A composed surface's container mounted and asks for its surface: compose
  # the recorded request again as the person, hold the result under its id,
  # and push it to that container alone.
  def handle_event("assistant:surface", %{"id" => id}, socket) when is_binary(id) do
    case socket.assigns.shown[id] do
      %{kind: :surface, request: request} -> {:noreply, show_surface(socket, id, request)}
      _ -> {:noreply, socket}
    end
  end

  # A client action in a composed surface: routed to the surface this page
  # holds under the envelope's id, through the handler (which authorizes as
  # the person). An id the page does not hold is ignored, never rebuilt.
  def handle_event("a2ui:action", %{"action" => %{"surfaceId" => id}} = envelope, socket) do
    case socket.assigns.surfaces[id] do
      nil ->
        {:noreply, socket}

      surface ->
        {_outcome, messages} =
          AshA2ui.Dynamic.handle_action(surface, envelope, a2ui_opts(socket))

        {:noreply, push_event(socket, "a2ui:messages:" <> id, %{messages: messages})}
    end
  end

  def handle_event("a2ui:action", _envelope, socket), do: {:noreply, socket}

  # A reference link in a composed surface: its deep link, re-authorized there.
  def handle_event("a2ui:open_surface", args, socket), do: Host.open_surface(args, socket)

  def handle_event("pin", %{"id" => id}, socket) do
    with true <- may_pin?(socket),
         %{kind: :surface, request: request} <- socket.assigns.shown[id] do
      {:noreply, pin(socket, request)}
    else
      _ -> {:noreply, assign(socket, :notice, {:error, "That view cannot be pinned."})}
    end
  end

  # The person's decision on their own request, as them: `Requests` reads only their
  # own, and approving or rejecting it goes through its task as them.
  def handle_event(decision, %{"id" => id}, socket) when decision in ["confirm", "cancel"] do
    case socket.assigns.shown[id] do
      %{kind: :request, status: :awaiting_approval, busy?: false} = item ->
        {:noreply, decide(socket, id, item, decision)}

      _ ->
        {:noreply, socket}
    end
  end

  defp ask(socket, ""), do: socket
  defp ask(%{assigns: %{run: %{}}} = socket, _question), do: socket

  defp ask(socket, question) do
    if may_ask?(socket),
      do: ask_as_member(socket, question),
      else:
        assign(socket, :notice, {:error, "The assistant is for active members of this tenant."})
  end

  defp ask_as_member(%{assigns: %{thread: nil}} = socket, question) do
    case Thread.start(title(question), actor_opts(socket)) do
      {:ok, thread} ->
        socket
        |> assign(thread: thread, empty?: false)
        |> stream(:turns, [], reset: true)
        |> push_patch(to: ~p"/app/agent/#{thread.id}")
        |> start_run({:ask, question})

      {:error, _error} ->
        assign(socket, :notice, {:error, "Could not start a conversation. Try again."})
    end
  end

  defp ask_as_member(socket, question), do: start_run(socket, {:ask, question})

  # Every event is a public endpoint: before anything is recorded or asked,
  # the person must be one the assistant's tools admit (self-service: an
  # active member in their own tenant). The reads behind every answer are
  # authorized again, row by row, as them.
  defp may_ask?(socket) do
    actor = socket.assigns.current_user

    Ash.can?({AshEnterprise.Assistant.Lookup.Person, :find_people}, actor,
      tenant: ActorContext.tenant(actor)
    )
  end

  defp show_surface(socket, id, request) do
    opts = actor_opts(socket)

    case Composer.compose(request, surface_id: id) do
      {:ok, composed} ->
        messages =
          AshA2ui.Dynamic.build_surface(
            composed.surface,
            Composer.build_opts(composed, a2ui_opts(socket, opts))
          )

        socket
        |> assign(:surfaces, Map.put(socket.assigns.surfaces, id, composed.surface))
        |> push_event("a2ui:messages:" <> id, %{messages: messages})

      {:error, _reasons} ->
        push_event(socket, "a2ui:refused:" <> id, %{
          message:
            "This view no longer matches the data it was composed over, so it is not shown."
        })
    end
  end

  # The person must be one who may pin (self-service: an active member in
  # their own tenant); the pin itself is then written as them.
  defp may_pin?(socket) do
    actor = socket.assigns.current_user
    Ash.can?({PinnedApp, :pin}, actor, tenant: ActorContext.tenant(actor))
  end

  defp pin(socket, request) do
    opts = actor_opts(socket)

    with {:ok, composed} <- Composer.compose(request),
         spec = AshA2ui.Dynamic.serialize(composed.surface),
         {:ok, mine} <- PinnedApp.mine(opts),
         false <- Enum.any?(mine, &(&1.spec == spec)),
         {:ok, _app} <-
           PinnedApp.pin(
             %{
               title: Composer.structural_title(composed.request),
               display: String.to_existing_atom(composed.request["display"] || "table"),
               source: composed.request["show"],
               spec: spec
             },
             opts
           ) do
      put_flash(socket, :info, "Pinned. It is under My apps on your launcher.")
    else
      true -> put_flash(socket, :info, "Already pinned: it is under My apps on your launcher.")
      _ -> assign(socket, :notice, {:error, "Could not pin that view. Try again."})
    end
  end

  defp retry(socket, question_id) do
    with true <- may_ask?(socket),
         %Thread{} = thread <- socket.assigns.thread,
         {:ok, %{turns: entries}} <- History.load(thread.id, actor_opts(socket)),
         %{turn: %Turn{role: :user} = question} <-
           Enum.find(entries, &(&1.turn.id == question_id)) do
      start_run(socket, {:retry, question})
    else
      _ -> assign(socket, :notice, {:error, "That question is no longer here to retry."})
    end
  end

  defp start_run(socket, request) do
    opts = actor_opts(socket)
    thread = socket.assigns.thread

    result =
      case request do
        {:ask, question} -> Ask.ask(thread, question, opts)
        {:retry, question} -> Ask.retry(thread, question, opts)
      end

    socket =
      socket
      |> assign(:notice, nil)
      |> assign(:form, to_form(%{"question" => ""}, as: :ask))

    case result do
      {:ok, %{question: question, run: run}} ->
        socket
        |> assign(:empty?, false)
        |> asked(request, question)
        |> attach(question.id, run.id)

      {:error, reason, %{question: question, answer: answer}} ->
        socket = if question, do: asked(socket, request, question), else: socket
        settle(socket, %{question_id: question && question.id, shown: []}, answer, reason)
    end
  end

  defp asked(socket, {:ask, _question}, question),
    do: socket |> assign(:empty?, false) |> stream_insert(:turns, entry(question))

  defp asked(socket, {:retry, _question}, _question_turn), do: socket

  # Follow the run `run_id`, answering `question_id`.
  defp attach(socket, question_id, run_id) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(AshEnterprise.PubSub, Ask.topic(run_id))
    now = System.monotonic_time(:second)
    Process.send_after(self(), {:tick, run_id}, 1_000)

    assign(socket, :run, %{
      id: run_id,
      question_id: question_id,
      text: "",
      calls: [],
      step: 1,
      phase: :waiting,
      started: now,
      heard: now,
      elapsed: 0,
      slow?: false,
      stopping?: false,
      shown: [],
      seen: 0
    })
  end

  # The run, read again as the person: settled into its answer once it has ended, its
  # progress otherwise, with any request it made as they read it.
  defp follow(thread, run_id, opts) do
    case Ask.settle(thread, run_id, opts) do
      {:pending, progress} ->
        rows = Map.new(Map.values(progress.requests), &{&1.id, &1})

        requests =
          for %{"request" => %{"id" => id, "invocation_id" => invocation_id}} <- progress.calls,
              row = rows[invocation_id],
              into: %{},
              do: {id, request_item(row, opts)}

        {:pending, progress, requests}

      settled ->
        {:settled, settled, requests_of(settled_turn(settled), opts)}
    end
  end

  defp settled_turn({:ok, turn}), do: turn
  defp settled_turn({:error, _reason, turn}), do: turn

  # -- the run --------------------------------------------------------------------

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "agent_runs:" <> run_id},
        %{assigns: %{run: %{id: run_id}}} = socket
      ),
      do: {:noreply, look(socket)}

  # An update from a run this page no longer follows.
  def handle_info(%Phoenix.Socket.Broadcast{topic: "agent_runs:" <> run_id}, socket) do
    Phoenix.PubSub.unsubscribe(AshEnterprise.PubSub, Ask.topic(run_id))
    {:noreply, socket}
  end

  def handle_info({:tick, run_id}, %{assigns: %{run: %{id: run_id} = run}} = socket) do
    now = System.monotonic_time(:second)
    run = %{run | elapsed: now - run.started, slow?: now - run.heard >= @slow_after_s}
    Process.send_after(self(), {:tick, run_id}, 1_000)
    socket = assign(socket, :run, run)

    if rem(run.elapsed, @poll_every_s) == 0,
      do: {:noreply, look(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:tick, _run_id}, socket), do: {:noreply, socket}

  # A request this page shows changed: read it again as the person.
  def handle_info(%Phoenix.Socket.Broadcast{topic: "invocations:" <> invocation_id}, socket) do
    case socket.assigns.requests[invocation_id] do
      nil -> {:noreply, socket}
      id -> {:noreply, look_request(socket, id, invocation_id)}
    end
  end

  defp look(%{assigns: %{run: %{stopping?: true}}} = socket), do: socket

  defp look(%{assigns: %{run: run, thread: thread}} = socket) do
    opts = actor_opts(socket)
    start_async(socket, {:run, run.id}, fn -> follow(thread, run.id, opts) end)
  end

  defp progressed(socket, progress, requests) do
    run = socket.assigns.run
    calls = Enum.map(progress.calls, &live_call/1)
    moved? = length(calls) + progress.model_calls != run.seen

    new =
      for call <- progress.calls,
          item <- [call["surface"], call["request"]],
          %{"id" => id} <- [item],
          not Map.has_key?(socket.assigns.shown, id),
          item == call["surface"] or Map.has_key?(requests, id),
          do: {id, call}

    socket =
      Enum.reduce(new, socket, fn
        {id, %{"surface" => %{"id" => id} = surface}}, socket ->
          put_shown(socket, id, %{
            kind: :surface,
            request: surface["request"],
            title: surface["title"],
            turn_id: nil
          })

        {id, _call}, socket ->
          item = requests[id]
          socket |> put_shown(id, item) |> follow_request(id, item)
      end)

    update_run(socket, fn run ->
      %{
        run
        | calls: calls,
          text: progress.text,
          step: progress.model_calls + 1,
          phase: if(Enum.any?(calls, &is_nil(&1.ok?)), do: :tool, else: :waiting),
          shown: run.shown ++ Enum.map(new, &elem(&1, 0)),
          seen: length(calls) + progress.model_calls,
          heard: if(moved?, do: System.monotonic_time(:second), else: run.heard),
          slow?: if(moved?, do: false, else: run.slow?)
      }
    end)
  end

  defp update_run(socket, fun), do: assign(socket, :run, fun.(socket.assigns.run))

  defp settle(socket, run, turn, reason, requests \\ %{}) do
    question_id = run.question_id
    shown_ids = run.shown

    socket =
      socket
      |> assign(:run, nil)
      |> load_threads()

    socket =
      case turn do
        %Turn{} ->
          socket
          |> adopt(turn, question_id, shown_ids, requests)
          |> then(&stream_insert(&1, :turns, entry(&1, turn, question_id)))

        nil ->
          socket
      end

    if reason && is_nil(turn),
      do: assign(socket, :notice, {:error, reason_message(reason)}),
      else: socket
  end

  @impl true
  def handle_async(:threads, {:ok, threads}, socket),
    do: {:noreply, assign(socket, :threads, threads)}

  def handle_async(:threads, _failed, socket), do: {:noreply, socket}

  def handle_async(
        :thread,
        {:ok, {:ok, %{thread: thread, turns: entries, requests: requests, live: live}}},
        socket
      ) do
    socket = Enum.reduce(entries, socket, &remember(&2, &1.turn, requests))
    entries = with_questions(socket, entries)

    # Answers whose requests can still change re-render when one does.
    answers =
      for %{turn: %Turn{role: :assistant} = turn, question_id: question_id} <- entries,
          into: socket.assigns.answers,
          do: {turn.id, {turn, question_id}}

    socket =
      socket
      |> assign(thread: thread, empty?: entries == [], answers: answers)
      |> stream(:turns, entries, reset: true)

    case live do
      {question_id, run_id} when is_nil(socket.assigns.run) ->
        {:noreply, socket |> attach(question_id, run_id) |> look()}

      _none ->
        {:noreply, socket}
    end
  end

  def handle_async(:thread, _not_found, socket) do
    {:noreply,
     socket
     |> assign(:notice, {:error, "That conversation was not found, or is not yours."})
     |> push_patch(to: ~p"/app/agent")}
  end

  def handle_async(
        {:run, run_id},
        {:ok, result},
        %{assigns: %{run: %{id: run_id} = run}} = socket
      ) do
    case result do
      {:pending, progress, requests} ->
        {:noreply, progressed(socket, progress, requests)}

      {:settled, {:ok, turn}, requests} ->
        {:noreply, settle(socket, run, turn, nil, requests)}

      {:settled, {:error, :stopped, turn}, requests} ->
        {:noreply, settle(socket, run, turn, nil, requests)}

      {:settled, {:error, reason, turn}, requests} ->
        {:noreply, settle(socket, run, turn, reason, requests)}
    end
  end

  # A look at a run this page no longer follows, or one that failed: the next update or
  # tick looks again.
  def handle_async({:run, _run_id}, _result, socket), do: {:noreply, socket}

  # A request read again, or decided by the person: as it now stands.
  # The decision and a read on the request's topic are separate tasks, so neither
  # supersedes the other's answer.
  def handle_async({task, id}, {:ok, {:ok, row}}, socket) when task in [:request, :decision],
    do: {:noreply, requested(socket, id, row)}

  def handle_async({:decision, id}, _failed, socket),
    do: {:noreply, decision_failed(socket, id)}

  def handle_async({:request, _id}, _failed, socket), do: {:noreply, socket}

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
    |> start_async(:thread, fn ->
      with {:ok, loaded} <- History.load(id, opts) do
        {loaded, live} = catch_up(loaded, opts)

        {:ok,
         loaded
         |> Map.put(:requests, restore_requests(loaded, opts))
         |> Map.put(:live, live)}
      end
    end)
  end

  # The thread's runs with no answer yet: one that has ended is recorded now (the page
  # that asked was closed before it did), and one still working is followed. Runs in
  # the thread's async load.
  defp catch_up(%{thread: thread, turns: entries} = loaded, opts) do
    {live, settled?} =
      thread
      |> Ask.pending(Enum.map(entries, & &1.turn), opts)
      |> Enum.reduce({nil, false}, fn {question_id, run}, {live, settled?} ->
        case Ask.settle(thread, run.id, opts) do
          {:pending, _progress} -> {{question_id, run.id}, settled?}
          _settled -> {live, true}
        end
      end)

    with true <- settled?, {:ok, reloaded} <- History.load(thread.id, opts) do
      {reloaded, live}
    else
      _ -> {loaded, live}
    end
  end

  # The thread's requests as they now stand, read as the person in the thread's async
  # load. One they can no longer read (not theirs, or gone) is left out.
  defp restore_requests(%{turns: entries}, opts) do
    for %{turn: %Turn{role: :assistant}, withheld?: false} = entry <- entries,
        reduce: %{},
        do: (requests -> Map.merge(requests, requests_of(entry.turn, opts)))
  end

  # One answer's requests as they now stand, read as the person.
  defp requests_of(%Turn{} = turn, opts) do
    for call <- calls(turn),
        %{"id" => id, "invocation_id" => invocation_id} <- [call["request"]],
        {:ok, row} <- [Requests.get(invocation_id, opts[:actor], opts[:tenant])],
        into: %{},
        do: {id, request_item(row, opts)}
  end

  defp requests_of(_no_turn, _opts), do: %{}

  defp entry(%Turn{} = turn), do: %{turn: turn, withheld?: false, question_id: nil, shown: []}

  defp entry(socket, %Turn{} = turn, question_id),
    do: %{turn: turn, withheld?: false, question_id: question_id, shown: shown_in(socket, turn)}

  # Each answer carries the question it answered, for Retry, and what it put
  # on the page.
  defp with_questions(socket, entries) do
    {entries, _} =
      Enum.map_reduce(entries, nil, fn %{turn: turn} = entry, question ->
        case turn.role do
          :user ->
            {Map.merge(entry, %{question_id: nil, shown: []}), turn.id}

          :assistant ->
            {Map.merge(entry, %{question_id: question, shown: shown_in(socket, turn)}), question}
        end
      end)

    entries
  end

  # -- what an answer put on the page --------------------------------------------

  defp put_shown(socket, id, item),
    do: assign(socket, :shown, Map.put(socket.assigns.shown, id, item))

  # The items a recorded answer carries, in call order, as this page knows them.
  defp shown_in(socket, %Turn{} = turn) do
    turn
    |> calls()
    |> Enum.flat_map(fn call ->
      [call["surface"], call["request"], call["proposal"]]
      |> Enum.flat_map(fn
        %{"id" => id} -> [{id, socket.assigns.shown[id]}]
        _ -> []
      end)
    end)
    |> Enum.reject(fn {_id, item} -> is_nil(item) end)
  end

  # A finished run's items now belong to its recorded answer.
  defp adopt(socket, %Turn{} = turn, question_id, ids, requests) do
    shown =
      Enum.reduce(ids, socket.assigns.shown, fn id, shown ->
        Map.update!(shown, id, &%{&1 | turn_id: turn.id})
      end)

    socket
    |> assign(:shown, shown)
    |> assign(:answers, Map.put(socket.assigns.answers, turn.id, {turn, question_id}))
    |> remember(turn, requests)
  end

  # Items of an answer read back from history: its surfaces can be shown
  # again (composed afresh when their container asks); its requests as they now
  # stand; a proposal from before requests as an earlier one, never offered.
  defp remember(socket, %Turn{role: :assistant} = turn, requests) do
    turn
    |> calls()
    |> Enum.reduce(socket, fn call, socket ->
      socket
      |> remember_surface(call["surface"], turn)
      |> remember_request(call["request"], turn, requests)
      |> remember_earlier(call["proposal"], turn)
    end)
  end

  defp remember(socket, _turn, _requests), do: socket

  defp remember_surface(socket, %{"id" => id, "request" => %{} = request} = surface, turn) do
    if Map.has_key?(socket.assigns.shown, id),
      do: socket,
      else:
        put_shown(socket, id, %{
          kind: :surface,
          request: request,
          title: surface["title"],
          turn_id: turn.id
        })
  end

  defp remember_surface(socket, _surface, _turn), do: socket

  defp remember_request(socket, %{"id" => id}, turn, requests) do
    cond do
      Map.has_key?(socket.assigns.shown, id) ->
        socket

      item = requests[id] ->
        socket |> put_shown(id, %{item | turn_id: turn.id}) |> follow_request(id, item)

      true ->
        socket
    end
  end

  defp remember_request(socket, _request, _turn, _requests), do: socket

  defp remember_earlier(socket, %{"id" => id} = proposal, turn) do
    if Map.has_key?(socket.assigns.shown, id),
      do: socket,
      else:
        put_shown(socket, id, %{kind: :earlier, summary: proposal["summary"], turn_id: turn.id})
  end

  defp remember_earlier(socket, _proposal, _turn), do: socket

  # -- requests -------------------------------------------------------------------

  # A request as the page shows it: its state, and what it would do as the person
  # reads it now.
  defp request_item(row, opts) do
    %{
      kind: :request,
      invocation_id: row.id,
      status: row.status,
      error_code: row.error_code,
      description: Requests.describe(row, opts[:actor], opts[:tenant]),
      busy?: false,
      failed?: false,
      turn_id: nil
    }
  end

  # An open request is followed on its own topic, once, so a decision made
  # elsewhere (another tab, the approvals inbox) shows here too.
  defp follow_request(socket, id, %{invocation_id: invocation_id, status: status}) do
    cond do
      status in Requests.final() ->
        socket

      Map.has_key?(socket.assigns.requests, invocation_id) ->
        socket

      not connected?(socket) ->
        socket

      true ->
        Phoenix.PubSub.subscribe(AshEnterprise.PubSub, "invocations:#{invocation_id}")
        assign(socket, :requests, Map.put(socket.assigns.requests, invocation_id, id))
    end
  end

  defp decide(socket, id, item, decision) do
    opts = actor_opts(socket)
    invocation_id = item.invocation_id

    socket
    |> put_shown(id, %{item | busy?: true, failed?: false})
    |> restream(id)
    |> start_async({:decision, id}, fn ->
      case decision do
        "confirm" -> Requests.confirm(invocation_id, opts[:actor], opts[:tenant])
        "cancel" -> Requests.decline(invocation_id, opts[:actor], opts[:tenant])
      end
    end)
  end

  defp look_request(socket, id, invocation_id) do
    opts = actor_opts(socket)

    start_async(socket, {:request, id}, fn ->
      case Requests.get(invocation_id, opts[:actor], opts[:tenant]) do
        {:ok, row} -> {:ok, row}
        :error -> {:error, :not_found}
      end
    end)
  end

  defp requested(socket, id, row) do
    case socket.assigns.shown[id] do
      %{kind: :request} = item ->
        item = %{item | status: row.status, error_code: row.error_code, busy?: false}

        socket =
          if row.status in Requests.final() do
            Phoenix.PubSub.unsubscribe(AshEnterprise.PubSub, "invocations:#{row.id}")
            assign(socket, :requests, Map.delete(socket.assigns.requests, row.id))
          else
            socket
          end

        socket |> put_shown(id, item) |> restream(id)

      _ ->
        socket
    end
  end

  defp decision_failed(socket, id) do
    case socket.assigns.shown[id] do
      %{kind: :request} = item ->
        socket |> put_shown(id, %{item | busy?: false, failed?: true}) |> restream(id)

      _ ->
        socket
    end
  end

  # An item's state changed: re-render the answer that carries it.
  defp restream(socket, id) do
    with %{turn_id: turn_id} when not is_nil(turn_id) <- socket.assigns.shown[id],
         {%Turn{} = turn, question_id} <- socket.assigns.answers[turn_id] do
      stream_insert(socket, :turns, entry(socket, turn, question_id))
    else
      _ -> socket
    end
  end

  defp actor_opts(socket) do
    actor = socket.assigns.current_user
    [actor: actor, tenant: ActorContext.tenant(actor), authorize?: true]
  end

  defp a2ui_opts(socket, opts \\ nil),
    do: (opts || actor_opts(socket)) ++ AshEnterpriseWeb.Locale.a2ui_opts(socket.assigns[:locale])

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

          <.live_turn :if={@run} run={@run} max_steps={@max_steps} shown={@shown} />

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
      <.shown_items items={@entry.shown} />
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
  attr :shown, :map, required: true

  defp live_turn(assigns) do
    assigns =
      assign(
        assigns,
        :items,
        for(id <- assigns.run.shown, item = assigns.shown[id], do: {id, item})
      )

    ~H"""
    <article
      id="live-turn"
      class="flex max-w-[92%] flex-col gap-3 rounded-base border-2 border-border bg-secondary-background px-4 py-3 shadow-shadow"
      aria-live="polite"
    >
      <.tool_calls calls={Enum.map(@run.calls, &shown_call/1)} />
      <p :if={@run.text != ""} class="whitespace-pre-wrap text-sm">{@run.text}</p>
      <.shown_items items={@items} prefix="live-" />
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

  attr :items, :list, required: true
  attr :prefix, :string, default: ""

  defp shown_items(assigns) do
    ~H"""
    <%= for {id, item} <- @items do %>
      <.composed :if={item.kind == :surface} id={id} item={item} prefix={@prefix} />
      <.request_card :if={item.kind == :request} id={id} item={item} prefix={@prefix} />
      <.callout
        :if={item.kind == :earlier}
        id={@prefix <> "earlier-" <> id}
        kind={:info}
        class="shadow-none"
        data-role="earlier"
      >
        {earlier_line(item.summary)}
      </.callout>
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :item, :map, required: true
  attr :prefix, :string, required: true

  # The container is the renderer's (`phx-update="ignore"`): it asks for its
  # surface when it mounts, and the page pushes that surface to it alone.
  defp composed(assigns) do
    ~H"""
    <section
      id={@prefix <> "composed-" <> @id}
      data-role="composed"
      class="flex flex-col rounded-base border-2 border-border bg-background"
    >
      <header class="flex flex-wrap items-center justify-between gap-2 border-b-2 border-border px-3 py-2">
        <h3 class="flex items-center gap-2 text-sm font-heading">
          <.icon name="hero-squares-2x2" class="size-4" />
          {@item.title || "Composed view"}
          <.badge title="Composed for this answer, checked against the schema, read as you">
            composed
          </.badge>
        </h3>
        <.button
          id={@prefix <> "pin-" <> @id}
          type="button"
          size="xs"
          phx-click="pin"
          phx-value-id={@id}
          title="Keep it under My apps on your launcher"
        >
          <.icon name="hero-bookmark" class="size-3.5" /> Pin
        </.button>
      </header>
      <div
        id={@prefix <> "surface-" <> @id}
        phx-hook="InlineA2ui"
        phx-update="ignore"
        data-surface-id={@id}
        class="min-h-24 p-2"
      >
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :item, :map, required: true
  attr :prefix, :string, required: true

  # A request awaiting the person: what it would do, and their Confirm or Cancel.
  defp request_card(%{item: %{status: :awaiting_approval}} = assigns) do
    ~H"""
    <.card
      id={@prefix <> "request-" <> @id}
      accent="yellow"
      class="gap-3"
      data-role="request"
      data-status="awaiting_approval"
    >
      <p class="text-xs font-heading uppercase tracking-wide text-foreground/70">
        {dgettext("assistant", "Waiting for your confirmation: nothing has happened yet")}
      </p>
      <p class="font-heading">{request_summary(@item.description)}</p>
      <dl
        :if={request_details(@item.description) != []}
        class="grid grid-cols-[8rem_1fr] gap-x-4 gap-y-1 text-sm"
      >
        <div :for={{label, value} <- request_details(@item.description)} class="contents">
          <dt class="text-foreground/70">{label}</dt>
          <dd class="whitespace-pre-wrap">{value}</dd>
        </div>
      </dl>
      <p class="text-xs text-foreground/70">
        {dgettext(
          "assistant",
          "If you confirm, it runs once, as you, under your permissions, and is recorded in the audit log."
        )}
      </p>
      <p :if={@item.failed?} class="text-xs text-red-700" role="alert">
        {dgettext("assistant", "That did not go through. Nothing was changed. Try again.")}
      </p>
      <div :if={@prefix == ""} class="flex justify-end gap-2">
        <.button
          id={"cancel-" <> @id}
          type="button"
          size="sm"
          variant="ghost"
          phx-click="cancel"
          phx-value-id={@id}
          disabled={@item.busy?}
        >
          {dgettext("assistant", "Cancel")}
        </.button>
        <.button
          id={"confirm-" <> @id}
          type="button"
          size="sm"
          variant="primary"
          phx-click="confirm"
          phx-value-id={@id}
          disabled={@item.busy?}
        >
          {dgettext("assistant", "Confirm")}
        </.button>
      </div>
    </.card>
    """
  end

  defp request_card(assigns) do
    ~H"""
    <.callout
      id={@prefix <> "request-" <> @id}
      kind={request_tone(@item)}
      class="shadow-none"
      data-role="request"
      data-status={@item.status}
    >
      {request_line(@item)}
    </.callout>
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
            <%!-- A change the run asked for: asked until the person decides, then ran. --%>
            <%= if is_map(call["request"]) do %>
              <.badge :if={call["ok"] == true} tone="green">{dgettext("assistant", "ran")}</.badge>
              <.badge :if={is_nil(call["ok"])} tone="yellow">
                {dgettext("assistant", "asked")}
              </.badge>
            <% else %>
              <.badge :if={call["ok"] == true} tone="green">{rows(call["count"])}</.badge>
              <.badge :if={is_nil(call["ok"])}>…</.badge>
            <% end %>
            <.badge :if={call["ok"] == false} tone="red">error</.badge>
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

  # -- what a request says ------------------------------------------------------------

  # What the request would do, in one line. A name the person can no longer read is
  # left out rather than guessed.
  defp request_summary(%{kind: :add_action_item, title: title}) when is_binary(title),
    do: dgettext("assistant", "Add the action item “%{title}”", title: title)

  defp request_summary(%{kind: :add_action_item}),
    do: dgettext("assistant", "Add an action item")

  defp request_summary(%{kind: :finish_action_item, title: title}) when is_binary(title),
    do: dgettext("assistant", "Mark “%{title}” done", title: title)

  defp request_summary(%{kind: :finish_action_item}),
    do: dgettext("assistant", "Mark one of your action items done")

  defp request_summary(%{kind: :draft_reply, subject: subject}) when is_binary(subject),
    do: dgettext("assistant", "Save a reply draft to “%{subject}”", subject: subject)

  defp request_summary(%{kind: :draft_reply}),
    do: dgettext("assistant", "Save a reply draft")

  defp request_summary(%{kind: :sync_account, account: account}) when is_binary(account),
    do: dgettext("assistant", "Sync your %{account} account now", account: account)

  defp request_summary(%{kind: :sync_account}),
    do: dgettext("assistant", "Sync one of your linked accounts now")

  defp request_summary(%{kind: :approve_task, task: task}) when is_binary(task),
    do: dgettext("assistant", "Approve “%{task}”", task: task)

  defp request_summary(%{kind: :approve_task}),
    do: dgettext("assistant", "Approve a task waiting on you")

  defp request_summary(%{kind: :reject_task, task: task}) when is_binary(task),
    do: dgettext("assistant", "Reject “%{task}”", task: task)

  defp request_summary(%{kind: :reject_task}),
    do: dgettext("assistant", "Reject a task waiting on you")

  defp request_summary(%{kind: :merge_duplicate, incoming: incoming, existing: existing})
       when is_binary(incoming) and is_binary(existing),
       do:
         dgettext("assistant", "Merge “%{incoming}” into “%{existing}”",
           incoming: incoming,
           existing: existing
         )

  defp request_summary(%{kind: :merge_duplicate}),
    do: dgettext("assistant", "Merge a possible duplicate")

  defp request_summary(%{kind: :keep_duplicate_separate, incoming: incoming, existing: existing})
       when is_binary(incoming) and is_binary(existing),
       do:
         dgettext("assistant", "Keep “%{incoming}” separate from “%{existing}”",
           incoming: incoming,
           existing: existing
         )

  defp request_summary(%{kind: :keep_duplicate_separate}),
    do: dgettext("assistant", "Keep a possible duplicate separate")

  defp request_summary(%{kind: :mark_duplicate_unsure, incoming: incoming, existing: existing})
       when is_binary(incoming) and is_binary(existing),
       do:
         dgettext("assistant", "Mark “%{incoming}” and “%{existing}” as unsure",
           incoming: incoming,
           existing: existing
         )

  defp request_summary(%{kind: :mark_duplicate_unsure}),
    do: dgettext("assistant", "Mark a possible duplicate as unsure")

  defp request_summary(_other), do: dgettext("assistant", "A change the assistant asked for")

  defp request_details(description) do
    [
      {dgettext("assistant", "Due"), description[:due]},
      {dgettext("assistant", "Draft"), description[:body]},
      {dgettext("assistant", "About"), description[:about]},
      {dgettext("assistant", "Comment"), description[:comment]}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
  end

  defp request_tone(%{status: :succeeded}), do: :success
  defp request_tone(%{status: :failed}), do: :error
  defp request_tone(%{status: :rejected, error_code: "approval_rejected"}), do: :info
  defp request_tone(%{status: :rejected}), do: :error
  defp request_tone(_item), do: :info

  defp request_line(%{status: :succeeded, description: description}),
    do: request_summary(description) <> ": " <> done_message(description.kind)

  defp request_line(%{status: :rejected, error_code: "approval_rejected"} = item),
    do:
      request_summary(item.description) <>
        ": " <>
        dgettext("assistant", "cancelled. Nothing was changed.")

  defp request_line(%{status: :rejected} = item),
    do:
      request_summary(item.description) <>
        ": " <>
        dgettext("assistant", "it could not be asked (%{reason}). Nothing was changed.",
          reason: item.error_code || "rejected"
        )

  defp request_line(%{status: :failed} = item),
    do:
      request_summary(item.description) <>
        ": " <>
        dgettext("assistant", "it did not go through (%{reason}). Nothing was changed.",
          reason: item.error_code || "failed"
        )

  defp request_line(%{status: :stale} = item),
    do:
      request_summary(item.description) <>
        ": " <>
        dgettext("assistant", "it no longer applies. Nothing was changed.")

  defp request_line(%{status: :cancelled} = item),
    do:
      request_summary(item.description) <>
        ": " <>
        dgettext("assistant", "withdrawn. Nothing was changed.")

  defp request_line(item),
    do: request_summary(item.description) <> ": " <> dgettext("assistant", "working on it…")

  defp done_message(:add_action_item), do: dgettext("assistant", "added to your action items.")
  defp done_message(:finish_action_item), do: dgettext("assistant", "marked done.")

  defp done_message(:draft_reply),
    do: dgettext("assistant", "draft saved. It was not sent.")

  defp done_message(:sync_account), do: dgettext("assistant", "sync queued.")
  defp done_message(:approve_task), do: dgettext("assistant", "approved.")
  defp done_message(:reject_task), do: dgettext("assistant", "rejected.")
  defp done_message(:merge_duplicate), do: dgettext("assistant", "merged.")
  defp done_message(:keep_duplicate_separate), do: dgettext("assistant", "kept separate.")

  defp done_message(:mark_duplicate_unsure),
    do: dgettext("assistant", "marked unsure; it stays in the queue.")

  defp done_message(_kind), do: dgettext("assistant", "done.")

  # A change proposed by an answer recorded before requests: shown, never offered.
  defp earlier_line(summary) when is_binary(summary) and summary != "",
    do: dgettext("assistant", "%{summary}: proposed (before 4 November 2026).", summary: summary)

  defp earlier_line(_summary),
    do: dgettext("assistant", "A change was proposed here (before 4 November 2026).")

  defp calls(%Turn{tool_calls: %{"calls" => calls}}) when is_list(calls), do: calls
  defp calls(_turn), do: []

  # A call as the run's journal names it, as the live turn shows it.
  defp live_call(call),
    do: %{
      name: call["name"],
      arguments: call["arguments"],
      ok?: call["ok"],
      count: call["count"],
      request: call["request"]
    }

  defp shown_call(call),
    do: %{
      "name" => call.name,
      "arguments" => call.arguments,
      "ok" => call.ok?,
      "count" => call.count,
      "request" => call.request
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

  def reason_message("step_cap"),
    do: "Stopped after #{Ask.max_steps()} model calls without an answer. Try a narrower question."

  def reason_message("budget"),
    do: "Stopped: this answer used its whole token budget. Try a narrower question."

  def reason_message("not_published"),
    do:
      "The assistant is not set up in this organization yet: an administrator requests " <>
        "its publish, another administrator approves it (or, where the organization " <>
        "allows it, its only administrator), and each member is given a start grant."

  def reason_message("not_permitted"),
    do:
      "You have not been given the assistant yet: an administrator grants you its start " <>
        "(the assistant agent's start grant)."

  def reason_message("denied"),
    do:
      "Stopped: you no longer hold what the assistant runs on (your account, your tenant " <>
        "or its start grant)."

  def reason_message("empty_answer"), do: "The model returned an empty answer. Try again."

  def reason_message("timeout"),
    do:
      "No answer within the assistant's time limit: the in-zone model may be down, busy or " <>
        "off the network. Nothing was sent anywhere else. Try again shortly."

  def reason_message(_other), do: "Something went wrong answering this. Try again."
end
