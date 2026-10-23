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

  ## Composed surfaces, inline

  When the model calls `compose_surface`, the runner hands this page the
  verified request (`{:surface, ...}`). The answer then carries a container
  for it (`InlineA2ui`, `assets/js/inline_a2ui_hook.js`), which asks for its
  surface once mounted; the page composes the request again **as the person**
  (`AshEnterprise.Assistant.Composer`), holds the resolved surface server-side
  under its id and pushes the A2UI messages to that container alone. Client
  actions are routed back to the held surface by its id — never rebuilt from
  anything the client sends. Pin saves the verified spec as a personal app
  (`AshEnterprise.Assistant.PinnedApp`), which lists under "My apps" on the
  launcher.

  ## Proposals wait for the person

  A proposal tool's result (`{:proposal, ...}`) is rebuilt here from its wire
  form as the person (`AshEnterprise.AI.Proposal.from_wire/3`) and shown with
  the concrete change and Confirm / Cancel. Confirm runs it with the person as
  the actor (`Proposal.execute/3`, which authorizes again); nothing runs
  otherwise. Decisions (approve or reject a task, a steward's verdict) are
  proposals like any other, resolved through the engine's candidacy read and
  the steward queue as the person.

  What the person did with each proposal is recorded
  (`AshEnterprise.Assistant.ProposalSettlement`): `:confirmed` before it
  runs, so a second confirm from another tab is refused rather than run
  twice. Reopening a thread offers its unsettled proposals again, each
  rebuilt from its wire form as the person and authorization-checked (in the
  thread's async load, never in mount); a settled one shows what happened.

  ## When the in-zone model is down or slow

  Nothing goes anywhere else. A run that has heard nothing for
  #{20} seconds says the model is slow and keeps the Stop button; at
  #{300} seconds the page stops it. A refused or failed run records the
  answer as failed with its reason, which the page explains.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.AI.{Models, Proposal}

  alias AshEnterprise.Assistant.{
    Answer,
    Composer,
    History,
    PinnedApp,
    ProposalSettlement,
    Runner,
    Thread,
    Turn
  }

  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2ui.Host
  alias AshEnterpriseWeb.AssistantHandoff
  alias AshEnterpriseWeb.Layouts

  @slow_after_s 20
  @give_up_after_s 300
  @force_stop_ms 3_000

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
     |> assign(:max_steps, Runner.max_steps())
     |> assign(:form, to_form(%{"question" => ""}, as: :ask))
     # What the model put on the page, by the page's own id: composed
     # surfaces (their verified requests) and proposals (rebuilt as the person,
     # with their state). `surfaces` holds each resolved surface server-side.
     |> assign(:shown, %{})
     |> assign(:surfaces, %{})
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
    send(run.pid, {:assistant_stop, run.ref})
    Process.send_after(self(), {:force_stop, run.ref}, @force_stop_ms)
    {:noreply, assign(socket, :run, %{run | stopping?: true})}
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
          AshA2ui.Dynamic.handle_action(surface, envelope, actor_opts(socket))

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

  def handle_event("confirm", %{"id" => id}, socket) do
    case socket.assigns.shown[id] do
      %{kind: :proposal, state: :pending, proposal: %Proposal{} = proposal} = item ->
        state = confirm(socket, id, proposal)
        {:noreply, socket |> put_shown(id, %{item | state: state}) |> restream(id)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    case socket.assigns.shown[id] do
      %{kind: :proposal, state: :pending} = item ->
        _ = record_settlement(socket, id, :cancelled)
        {:noreply, socket |> put_shown(id, %{item | state: :cancelled}) |> restream(id)}

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
        |> start_run(question: question)

      {:error, _error} ->
        assign(socket, :notice, {:error, "Could not start a conversation. Try again."})
    end
  end

  defp ask_as_member(socket, question), do: start_run(socket, question: question)

  # Every event is a public endpoint: before anything is recorded or asked,
  # the person must be one the assistant's tools admit (self-service: an
  # active member in their own tenant). The reads behind every answer are
  # authorized again, row by row, as them.
  defp may_ask?(socket) do
    actor = socket.assigns.current_user

    Ash.can?({AshEnterprise.Assistant.Lookup, :find_people}, actor,
      tenant: ActorContext.tenant(actor)
    )
  end

  defp show_surface(socket, id, request) do
    opts = actor_opts(socket)

    case Composer.compose(request, surface_id: id) do
      {:ok, composed} ->
        messages =
          AshA2ui.Dynamic.build_surface(composed.surface, Composer.build_opts(composed, opts))

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

  # A confirm is recorded before the proposal runs: the record's identity is
  # what stops a second confirm (another tab) from running it twice.
  defp confirm(socket, id, proposal) do
    case record_settlement(socket, id, :confirmed) do
      {:ok, _settled} ->
        state = execute(socket, proposal)
        if match?({:failed, _}, state), do: record_settlement(socket, id, :failed)
        state

      {:error, _already} ->
        {:failed, "It was already confirmed, so it was not run again."}
    end
  end

  defp record_settlement(%{assigns: %{thread: %Thread{id: thread_id}}} = socket, id, outcome)
       when is_binary(thread_id),
       do: ProposalSettlement.settle(thread_id, id, outcome, actor_opts(socket))

  defp record_settlement(_socket, _id, _outcome), do: {:error, :no_thread}

  # Runs a confirmed proposal as the person; what the answer then says.
  defp execute(socket, proposal) do
    actor = socket.assigns.current_user

    case Proposal.execute(proposal, actor, ActorContext.tenant(actor)) do
      {:ok, result} ->
        {:done, done_message(proposal.kind, result)}

      {:error, message} when is_binary(message) ->
        {:failed, message}

      {:error, %Ash.Error.Forbidden{}} ->
        {:failed, "You may not decide this, or it was decided meanwhile. Nothing was changed."}

      {:error, _error} ->
        {:failed, "It could not be done. Nothing was changed."}
    end
  end

  defp done_message(:create_task, _task), do: "Added to your action items."
  defp done_message(:complete_task, _task), do: "Marked done."
  defp done_message(:draft_reply, _draft), do: "Draft saved. It was not sent."
  defp done_message(:decide_task, message) when is_binary(message), do: message
  defp done_message(:steward_verdict, %{status: :confirmed}), do: "Merged."
  defp done_message(:steward_verdict, %{status: :rejected}), do: "Kept separate."
  defp done_message(:steward_verdict, _candidate), do: "Marked unsure; it stays in the queue."

  defp done_message(:sync_now, results) when is_list(results),
    do: "Sync queued for #{length(results)} account(s)."

  defp done_message(_kind, _result), do: "Done."

  defp retry(socket, question_id) do
    with true <- may_ask?(socket),
         %Thread{} = thread <- socket.assigns.thread,
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
          stopping?: false,
          shown: []
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

  defp on_event({:surface, %{id: id, request: request, title: title}}, socket) do
    socket
    |> put_shown(id, %{kind: :surface, request: request, title: title, turn_id: nil})
    |> update_run(&%{&1 | shown: &1.shown ++ [id]})
  end

  defp on_event({:proposal, %{id: id, wire: wire}}, socket) do
    socket
    |> put_shown(id, rebuild_proposal(socket.assigns.current_user, wire))
    |> update_run(&%{&1 | shown: &1.shown ++ [id]})
  end

  defp on_event({:done, turn}, socket), do: settle(socket, turn, nil)
  defp on_event({:failed, reason, turn}, socket), do: settle(socket, turn, reason)
  defp on_event(_other, socket), do: socket

  defp update_run(socket, fun), do: assign(socket, :run, fun.(socket.assigns.run))

  defp settle(socket, turn, reason) do
    question_id = socket.assigns.run.question_id
    shown_ids = socket.assigns.run.shown

    socket =
      socket
      |> assign(:run, nil)
      |> load_threads()

    socket =
      case turn do
        %Turn{} ->
          socket
          |> adopt(turn, question_id, shown_ids)
          |> then(&stream_insert(&1, :turns, entry(&1, turn, question_id)))

        nil ->
          socket
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

  def handle_async(
        :thread,
        {:ok, {:ok, %{thread: thread, turns: entries, proposals: proposals}}},
        socket
      ) do
    socket = Enum.reduce(entries, socket, &remember(&2, &1.turn, proposals))
    entries = with_questions(socket, entries)

    # Answers whose proposals can still be confirmed re-render when one is.
    answers =
      for %{turn: %Turn{role: :assistant} = turn, question_id: question_id} <- entries,
          into: socket.assigns.answers,
          do: {turn.id, {turn, question_id}}

    {:noreply,
     socket
     |> assign(thread: thread, empty?: entries == [], answers: answers)
     |> stream(:turns, entries, reset: true)}
  end

  def handle_async(:thread, _not_found, socket) do
    {:noreply,
     socket
     |> assign(:notice, {:error, "That conversation was not found, or is not yours."})
     |> push_patch(to: ~p"/app/agent")}
  end

  def handle_async(:give_up, {:ok, {:ok, %{turns: entries}}}, socket) do
    {:noreply, stream(socket, :turns, with_questions(socket, entries), reset: true)}
  end

  def handle_async(:give_up, _result, socket), do: {:noreply, socket}

  # -- loading ----------------------------------------------------------------------

  defp load_threads(socket) do
    opts = actor_opts(socket)
    start_async(socket, :threads, fn -> History.threads(opts) end)
  end

  defp load_thread(socket, id) do
    opts = actor_opts(socket)
    actor = socket.assigns.current_user

    socket
    |> assign(:thread, %Thread{id: id})
    |> stream(:turns, [], reset: true)
    |> start_async(:thread, fn ->
      with {:ok, loaded} <- History.load(id, opts) do
        {:ok, Map.put(loaded, :proposals, restore_proposals(loaded, actor, opts))}
      end
    end)
  end

  # The thread's proposals as the page shows them again: a settled one as
  # what happened to it, an unsettled one rebuilt from its wire form as the
  # person and offered again (or why it no longer can be). Runs in the
  # thread's async load. Only proposals recorded as settled through
  # `ProposalSettlement` qualify: an older one may have been confirmed
  # before anything recorded it, so it is shown as earlier, never offered.
  defp restore_proposals(%{thread: thread, turns: entries}, actor, opts) do
    settled =
      case ProposalSettlement.for_thread(thread.id, opts) do
        {:ok, rows} -> Enum.reduce(rows, %{}, &settled_outcome/2)
        _ -> %{}
      end

    for %{turn: %Turn{role: :assistant}, withheld?: false} = entry <- entries,
        call <- calls(entry.turn),
        %{"id" => id, "wire" => %{} = wire, "settled" => "recorded"} = proposal <-
          [call["proposal"]],
        into: %{} do
      {id, restored(settled[id], proposal["summary"], actor, wire)}
    end
  end

  # A failure after a confirm outranks the confirm.
  defp settled_outcome(row, acc),
    do:
      Map.update(
        acc,
        row.proposal_ref,
        row.outcome,
        &if(&1 == :failed, do: &1, else: row.outcome)
      )

  defp restored(:confirmed, summary, _actor, _wire),
    do: settled_item(summary, {:done, "confirmed earlier."})

  defp restored(:cancelled, summary, _actor, _wire), do: settled_item(summary, :cancelled)

  defp restored(:failed, summary, _actor, _wire),
    do: settled_item(summary, {:failed, "It did not go through when it was confirmed."})

  defp restored(nil, summary, actor, wire) do
    case rebuild_proposal(actor, wire) do
      %{state: :pending} = item -> item
      %{state: {:failed, message}} -> settled_item(summary, {:stale, message})
    end
  end

  defp settled_item(summary, state),
    do: %{kind: :proposal, summary: summary, proposal: nil, state: state, turn_id: nil}

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
      [call["surface"], call["proposal"]]
      |> Enum.flat_map(fn
        %{"id" => id} -> [{id, socket.assigns.shown[id]}]
        _ -> []
      end)
    end)
    |> Enum.reject(fn {_id, item} -> is_nil(item) end)
  end

  # A finished run's items now belong to its recorded answer.
  defp adopt(socket, %Turn{} = turn, question_id, ids) do
    shown =
      Enum.reduce(ids, socket.assigns.shown, fn id, shown ->
        Map.update!(shown, id, &%{&1 | turn_id: turn.id})
      end)

    socket
    |> assign(:shown, shown)
    |> assign(:answers, Map.put(socket.assigns.answers, turn.id, {turn, question_id}))
    |> remember(turn, %{})
  end

  # Items of an answer read back from history: its surfaces can be shown
  # again (composed afresh when their container asks); its proposals are
  # shown as earlier ones, never offered again.
  defp remember(socket, %Turn{role: :assistant} = turn, proposals) do
    turn
    |> calls()
    |> Enum.reduce(socket, fn call, socket ->
      socket
      |> remember_surface(call["surface"], turn)
      |> remember_proposal(call["proposal"], turn, proposals)
    end)
  end

  defp remember(socket, _turn, _proposals), do: socket

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

  defp remember_proposal(socket, %{"id" => id} = proposal, turn, proposals) do
    cond do
      Map.has_key?(socket.assigns.shown, id) ->
        socket

      item = proposals[id] ->
        put_shown(socket, id, %{item | turn_id: turn.id})

      true ->
        put_shown(socket, id, %{
          kind: :proposal,
          summary: proposal["summary"],
          proposal: nil,
          state: :earlier,
          turn_id: turn.id
        })
    end
  end

  defp remember_proposal(socket, _proposal, _turn, _proposals), do: socket

  defp rebuild_proposal(actor, wire) do
    tenant = ActorContext.tenant(actor)

    with {:ok, proposal} <- Proposal.from_wire(wire, actor, tenant),
         :ok <- Proposal.authorize(proposal, actor, tenant) do
      %{
        kind: :proposal,
        summary: proposal.summary,
        proposal: proposal,
        state: :pending,
        turn_id: nil
      }
    else
      {:error, message} ->
        %{kind: :proposal, summary: nil, proposal: nil, state: {:failed, message}, turn_id: nil}
    end
  end

  # A proposal's state changed: re-render the answer that carries it.
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
      <.tool_calls calls={Enum.map(@run.calls, &live_call/1)} />
      <p :if={@run.text != ""} class="whitespace-pre-wrap text-sm">
        {@run.text}<span class="animate-pulse">▍</span>
      </p>
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
      <.proposal_card :if={item.kind == :proposal} id={id} item={item} prefix={@prefix} />
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

  defp proposal_card(%{item: %{state: :pending}} = assigns) do
    ~H"""
    <.card id={@prefix <> "proposal-" <> @id} accent="yellow" class="gap-3" data-role="proposal">
      <p class="text-xs font-heading uppercase tracking-wide text-foreground/70">
        Proposed — nothing has happened yet
      </p>
      <p class="font-heading">{@item.summary}</p>
      <dl class="grid grid-cols-[8rem_1fr] gap-x-4 gap-y-1 text-sm">
        <div :for={{label, value} <- details(@item.proposal)} class="contents">
          <dt class="text-foreground/70">{label}</dt>
          <dd class="whitespace-pre-wrap">{value}</dd>
        </div>
      </dl>
      <p class="text-xs text-foreground/70">
        Runs as you, under your permissions, and is recorded in the audit log.
      </p>
      <div :if={@prefix == ""} class="flex justify-end gap-2">
        <.button
          id={"cancel-" <> @id}
          type="button"
          size="sm"
          variant="ghost"
          phx-click="cancel"
          phx-value-id={@id}
        >
          Cancel
        </.button>
        <.button
          id={"confirm-" <> @id}
          type="button"
          size="sm"
          variant="primary"
          phx-click="confirm"
          phx-value-id={@id}
        >
          Confirm
        </.button>
      </div>
    </.card>
    """
  end

  defp proposal_card(assigns) do
    ~H"""
    <.callout id={@prefix <> "proposal-" <> @id} kind={proposal_kind(@item.state)} class="shadow-none">
      {proposal_line(@item)}
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

  defp details(%Proposal{details: details}) when is_list(details) do
    for {label, value} <- details, value not in [nil, ""] do
      {label |> to_string() |> String.replace("_", " ") |> String.capitalize(), value}
    end
  end

  defp details(_proposal), do: []

  defp proposal_kind({:done, _message}), do: :success
  defp proposal_kind({:failed, _message}), do: :error
  defp proposal_kind({:stale, _message}), do: :info
  defp proposal_kind(_state), do: :info

  defp proposal_line(%{state: {:done, message}, summary: summary}), do: "#{summary}: #{message}"

  defp proposal_line(%{state: {:failed, message}, summary: nil}),
    do: "Not proposed: #{message}"

  defp proposal_line(%{state: {:failed, message}, summary: summary}),
    do: "#{summary}: not done. #{message}"

  defp proposal_line(%{state: :cancelled, summary: summary}),
    do: "#{summary}: cancelled. Nothing was changed."

  defp proposal_line(%{state: {:stale, message}, summary: summary}),
    do: "Proposed earlier: #{summary || "a change"}. It can no longer be offered: #{message}"

  defp proposal_line(%{state: :earlier, summary: summary}),
    do:
      "Proposed earlier: #{summary || "a change"}. It is not offered again here; " <>
        "ask again if you still want it."

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

  def reason_message("awaiting_approval"),
    do:
      "A lookup needed approval before it could run, and the assistant cannot wait for one " <>
        "mid-answer. Nothing past that point was run."

  def reason_message("tool_paused"),
    do: "A lookup paused before it could answer. Nothing past that point was run. Try again."

  def reason_message("empty_answer"), do: "The model returned an empty answer. Try again."

  def reason_message("timeout"),
    do:
      "The in-zone model took longer than #{div(@give_up_after_s, 60)} minutes, so the page stopped waiting."

  def reason_message(_other), do: "Something went wrong answering this. Try again."
end
