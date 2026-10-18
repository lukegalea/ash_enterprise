defmodule AshEnterpriseWeb.AgentLive do
  @moduledoc """
  The helper agent console.

  Ask for something in plain language. The console either shows you a table, or
  shows you exactly what it proposes to change and waits.

  ## Three things it can do, and why they are not the same shape

      "assign the Administrator role to dana@corp.example"
        --> Interpreter     (model plans; holds no tools, changes nothing)
        --> Proposal        (names resolved AS YOU, authorization pre-checked)
        --> confirmation    (you read the concrete mutation)
        --> Proposal.execute with YOU as the actor
        --> policies, then the audit log

      "show me the legacy users"
        --> Interpreter     --> a DECLARED surface, from the registry
        --> rendered immediately, filtered by YOUR policies

      "legacy users, just login and email, sorted by login"
        --> Interpreter     --> a spec the model COMPOSED
        --> resolved against an allowlist, verified, then rendered
            (a refused spec goes back to the model once with the reasons;
            the person reads a plain sentence, never a verifier's message)

      "what's on my calendar on Monday"
        --> Interpreter     --> the person's OWN records: not this console's
        --> handed to the assistant at /app/agent, which reads them as you

  The write waits for a human. **The reads do not**, and that asymmetry is the
  point rather than an oversight. A table is filtered by the viewer's own
  policies before a single row reaches the page, so there is nothing for a person
  to decide by looking at it — and asking somebody to approve a read they are
  already authorized for is what teaches them to click through the confirmation
  that matters.

  ## The model never holds a mutation, and never holds a renderer

  It returns a struct: an `AshEnterprise.AI.Intent`, or a table *spec*. Neither
  can do anything. A spec is not UI — every resource, field and action name in it
  is resolved against a host-configured allowlist and run through the same
  verifiers the compile-time DSL runs, and a spec naming a field that does not
  exist is refused with an error rather than rendered blank.

  That is a structural guarantee rather than a prompt instruction, which is what
  makes prompt injection uninteresting here: there is no tool to trick it into
  calling, and no path from generated text to the page that skips the checks.

  ## Surfaces the agent shows are live

  A surface whose resource publishes notifications keeps updating after it is
  rendered — including when the writer was a different application entirely. Ask
  for the legacy users, then write to `legacy.users` with `psql`, and the row
  appears. See `AshEnterpriseWeb.A2uiLive.LegacyUsers` for that chain and
  `priv/legacy/README.md` for the commands.

  See `docs/manifesto/05-agents-are-users.md`.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.AI.Interpreter
  alias AshEnterprise.AI.Proposal
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2ui.Host
  alias AshEnterpriseWeb.AssistantHandoff
  alias AshEnterpriseWeb.Layouts
  alias Phoenix.LiveView.JS

  on_mount {AshEnterpriseWeb.LiveUserAuth, :live_user_required}

  @cue_visible_ms 6_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:request, "")
     |> assign(:proposal, nil)
     |> assign(:error, nil)
     |> assign(:result, nil)
     |> assign(:thinking?, false)
     |> assign(:presentation, nil)
     |> assign(:refresh_scheduled?, false)
     |> assign(:cue, nil)
     |> assign(:cue_ref, nil)}
  end

  @impl true
  def handle_event("propose", %{"request" => request}, socket) do
    actor = socket.assigns.current_user
    tenant = tenant(socket)

    socket = assign(socket, request: request, error: nil, result: nil, proposal: nil)

    case Interpreter.interpret(request, actor, tenant) do
      {:ok, plan} -> {:noreply, carry_out(plan, socket, actor, tenant)}
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("approve", _params, %{assigns: %{proposal: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("approve", _params, socket) do
    actor = socket.assigns.current_user

    case Proposal.execute(socket.assigns.proposal, actor, tenant(socket)) do
      {:ok, _record} ->
        {:noreply,
         socket
         |> assign(:proposal, nil)
         |> assign(:request, "")
         |> assign(:result, "Done. #{socket.assigns.proposal.summary}.")}

      {:error, %{__exception__: true} = error} ->
        {:noreply, assign(socket, :error, Exception.message(error))}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("reject", _params, socket) do
    {:noreply,
     assign(socket, proposal: nil, error: nil, result: "Cancelled. Nothing was changed.")}
  end

  # The declared surfaces, one click away. A person who already knows which table
  # they want should not have to spend a model call and a round trip to say so --
  # and the console should still be useful when no API key is configured, which
  # is the state a fresh checkout is in.
  def handle_event("show-surface", %{"name" => name}, socket) do
    case AshEnterprise.Surfaces.fetch_helper(name, socket.assigns.current_user) do
      nil ->
        {:noreply, assign(socket, :error, "No surface named #{inspect(name)}.")}

      surface ->
        socket =
          socket
          |> assign(error: nil, proposal: nil, request: "")
          |> present(Host.declared(surface), socket.assigns.current_user, tenant(socket))

        {:noreply, socket}
    end
  end

  def handle_event("dismiss-surface", _params, socket) do
    Host.dismiss(socket.assigns.presentation)

    {:noreply, assign(socket, presentation: nil, cue: nil)}
  end

  # The client interacted with the rendered surface. Routed through the handler
  # rather than into an Ash action directly: the handler is what enforces the
  # row-action allowlist, `visible_when`, and the error contract that puts
  # validation messages on the reserved `/errors/<field>` paths.
  def handle_event("a2ui:action", envelope, %{assigns: %{presentation: nil}} = socket) do
    # Nothing is being shown, so there is nothing this envelope can refer to.
    # Rebuilding a surface from something the client echoed back is exactly the
    # tamper-proofing hole the server-held presentation exists to close.
    _ = envelope
    {:noreply, socket}
  end

  def handle_event("a2ui:action", envelope, socket) do
    {socket, presentation} =
      Host.handle_action(
        socket,
        socket.assigns.presentation,
        envelope,
        actor: socket.assigns.current_user,
        tenant: tenant(socket)
      )

    {:noreply, assign(socket, :presentation, presentation)}
  end

  # A reference link in the hosted surface: navigate to its deep link, which
  # re-authorizes the record (`AshEnterpriseWeb.RecordController`).
  def handle_event("a2ui:open_surface", args, socket), do: Host.open_surface(args, socket)

  @impl true
  def handle_info(:clear_cue, socket) do
    {:noreply, assign(socket, cue: nil, cue_ref: nil)}
  end

  # The debounce window closed: rebuild the rows and raise the cue together. The
  # cue is deliberately NOT raised when the broadcast arrives -- announcing an
  # update 150 ms before it lands reads as a bug even though nothing is wrong.
  def handle_info({:ash_a2ui_host, :refresh}, %{assigns: %{presentation: nil}} = socket) do
    {:noreply, assign(socket, :refresh_scheduled?, false)}
  end

  def handle_info({:ash_a2ui_host, :refresh}, socket) do
    {socket, presentation} =
      Host.refresh(socket, socket.assigns.presentation,
        actor: socket.assigns.current_user,
        tenant: tenant(socket)
      )

    if socket.assigns.cue_ref, do: Process.cancel_timer(socket.assigns.cue_ref)
    ref = Process.send_after(self(), :clear_cue, @cue_visible_ms)

    {:noreply,
     socket
     |> assign(:presentation, presentation)
     |> assign(:refresh_scheduled?, false)
     |> assign(:cue, (socket.assigns.cue || 0) + 1)
     |> assign(:cue_ref, ref)}
  end

  # Anything else while a surface is subscribed is a notification on one of its
  # topics. Ash's PubSub notifier can send a %Notification{}, a
  # %Phoenix.Socket.Broadcast{} or a bare map depending on `broadcast_type`, so
  # this matches on none of them and coalesces whatever arrives.
  def handle_info(_message, %{assigns: %{presentation: nil}} = socket), do: {:noreply, socket}

  def handle_info(_message, socket) do
    case Host.schedule_refresh(socket.assigns.refresh_scheduled?) do
      :scheduled -> {:noreply, assign(socket, :refresh_scheduled?, true)}
      :already_scheduled -> {:noreply, socket}
    end
  end

  # A write: hold it, show it, and wait. Authorization is pre-flighted so the
  # confirmation is only ever shown for something that can actually happen --
  # asking someone to confirm an action that will then fail trains them to click
  # through errors.
  defp carry_out({:proposal, proposal}, socket, actor, tenant) do
    case Proposal.authorize(proposal, actor, tenant) do
      :ok -> assign(socket, :proposal, proposal)
      {:error, message} -> assign(socket, :error, message)
    end
  end

  # A read: show it. No confirmation, because the surface is built by running the
  # resource's own read action with this user as the actor -- the rows a person
  # sees are the rows their policies allow, decided before anything renders.
  defp carry_out({:surface, surface}, socket, actor, tenant) do
    present(socket, Host.declared(surface), actor, tenant)
  end

  defp carry_out({:designed, surface, title}, socket, actor, tenant) do
    present(socket, Host.dynamic(surface, title), actor, tenant)
  end

  # A question about the person's own calendar, mail or tasks: the assistant
  # answers it, as them. The question goes there in an encrypted token bound
  # to this user, never as text in the URL.
  defp carry_out({:assistant, question}, socket, actor, _tenant) do
    push_navigate(socket, to: ~p"/app/agent?#{[ask: AssistantHandoff.token(actor, question)]}")
  end

  defp present(socket, presentation, actor, tenant) do
    # Drop the previous subscription first. Without this, asking for three
    # surfaces in a row leaves the LiveView subscribed to all three and a write
    # to any of them refreshes a surface nobody is looking at.
    Host.dismiss(socket.assigns.presentation)

    {socket, presentation} =
      Host.present(socket, presentation, actor: actor, tenant: tenant)

    socket
    |> assign(:presentation, presentation)
    |> assign(:cue, nil)
    |> assign(:result, nil)
  end

  # Not `current_user.organization_id`: `User` is `tenant?: false` and has no such
  # attribute, so the direct access raises `KeyError` the moment anyone submits a
  # request. The tenant comes off the context the plug already resolved.
  defp tenant(socket) do
    ActorContext.tenant(socket.assigns[:current_user])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page={assigns[:page]}
      width={if(@presentation, do: "max-w-7xl", else: "max-w-3xl")}
    >
      <div class="space-y-6">
        <header>
          <h1 class="text-2xl font-heading tracking-tight">Helper</h1>
          <p class="text-foreground/70 text-sm">
            Ask for an administrative change. Nothing happens until you approve it.
          </p>
        </header>

        <form phx-submit="propose" class="flex w-full gap-3" id="agent-request">
          <input
            type="text"
            name="request"
            value={@request}
            placeholder="Show me the legacy users"
            class="h-10 w-full rounded-base border-2 border-border bg-secondary-background px-3 py-2 text-sm font-base text-foreground placeholder:text-foreground/60 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
            autocomplete="off"
          />
          <.button type="submit" variant="primary">Ask</.button>
        </form>

        <p class="text-foreground/70 text-xs">
          Try: <span class="font-mono">show me the legacy users</span>
          · <span class="font-mono">list all roles</span>
          · <span class="font-mono">legacy users, just login and email, sorted by login</span>
          · <span class="font-mono">assign the Administrator role to admin@legacy.example</span>
        </p>

        <div class="flex flex-wrap items-center gap-2">
          <span class="text-foreground/70 text-xs">or open one directly:</span>
          <.button
            :for={surface <- AshEnterprise.Surfaces.helper()}
            phx-click="show-surface"
            phx-value-name={surface.key}
            id={"open-#{surface.key}"}
            size="xs"
          >
            {surface.label}
          </.button>
        </div>

        <.callout :if={@error} kind={:error} role="alert">
          <span class="whitespace-pre-line">{@error}</span>
        </.callout>

        <.callout :if={@result} kind={:success} role="status">
          <span>{@result}</span>
        </.callout>

        <%!--
        The confirmation. This is the human-in-the-loop step: the proposal is
        inert until "Approve" is pressed, and the mutation then runs with THIS
        user as the actor -- so the audit entry names the person who decided,
        not the model that suggested.
      --%>
        <.card :if={@proposal} accent="yellow" class="gap-4" data-role="proposal">
          <h2 class="text-base font-heading">Confirm this change</h2>

          <p class="text-lg">{@proposal.summary}</p>

          <%!--
            `display: contents` rather than a `<template>`. A `<template>` element
            is inert: the browser parses its children into a document fragment and
            never renders them, so the details -- the concrete user, role and scope
            being changed -- were silently absent from every confirmation, leaving
            only the one-line summary to approve. A plain wrapper would render but
            would also break the two-column grid, since the dt/dd pairs would no
            longer be grid items; `contents` keeps both.
          --%>
          <dl class="grid grid-cols-[8rem_1fr] gap-x-4 gap-y-1 text-sm">
            <div :for={{label, value} <- @proposal.details} class="contents">
              <dt class="text-foreground/70">{label |> to_string() |> String.capitalize()}</dt>
              <dd>{value}</dd>
            </div>
          </dl>

          <p class="text-foreground/70 text-xs">
            Runs as you, through the same permissions as the admin UI, and is recorded in the audit log.
          </p>

          <div class="flex justify-end gap-3">
            <.button phx-click="reject" variant="ghost">Cancel</.button>
            <.button phx-click="approve" data-role="approve" variant="primary">Approve</.button>
          </div>
        </.card>

        <%!--
        The surface the agent chose or composed. The container is always in the
        DOM once something has been shown, because the renderer owns it
        (`phx-update="ignore"`) and LiveView must not remove and re-add a node it
        has been told to keep out of -- the hook would remount with no surface.
        Dismissing hides the wrapper instead.
      --%>
        <div :if={@presentation} class="space-y-3" data-role="surface">
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="flex items-center gap-2 text-lg font-heading">
                {@presentation.title}
                <.badge
                  :if={@presentation.kind == :dynamic}
                  title="Composed for this request, then validated against the schema"
                >
                  composed
                </.badge>
                <.badge
                  :if={@presentation.topics != []}
                  tone="green"
                  title="This surface updates itself when the underlying rows change"
                >
                  live
                </.badge>
              </h2>
              <p :if={@presentation.subtitle} class="text-foreground/70 text-sm">
                {@presentation.subtitle}
              </p>
            </div>
            <.button phx-click="dismiss-surface" variant="ghost" size="sm">Dismiss</.button>
          </div>

          <%!--
          Keyed on the counter so the element is genuinely removed and re-added
          for each refresh, which is what makes `phx-mounted` fire again rather
          than only on the first change.
        --%>
          <div :if={@cue} id={"agent-cue-#{@cue}"}>
            <div
              class="flex items-center gap-2.5 rounded-base border-2 border-border bg-yellow px-4 py-2 text-sm text-on-vivid shadow-shadow"
              phx-mounted={
                JS.transition(
                  {"transition-all duration-500 ease-out", "opacity-0 -translate-y-1",
                   "opacity-100 translate-y-0"},
                  time: 500
                )
              }
            >
              <span class="relative flex size-2">
                <span class="absolute inline-flex size-2 animate-ping rounded-full bg-on-vivid opacity-60" />
                <span class="relative inline-flex size-2 rounded-full bg-on-vivid" />
              </span>
              <span>
                Another application changed these rows. The table was rebuilt
                <span :if={@cue > 1} class="font-heading">({@cue} updates)</span>
              </span>
            </div>
          </div>
        </div>

        <div class={["", if(!@presentation, do: "hidden")]}>
          {AshA2ui.LiveRenderer.surface_container(assigns)}
        </div>
      </div>
    </Layouts.app>
    """
  end
end
