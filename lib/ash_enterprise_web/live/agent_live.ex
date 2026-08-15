defmodule AshEnterpriseWeb.AgentLive do
  @moduledoc """
  The helper agent console.

  Ask for something in plain language; the console shows you exactly what it
  proposes to do; nothing happens until you approve it.

  The flow, and why each step is where it is:

      request  --> Interpreter   (model plans; holds no tools, changes nothing)
               --> Proposal      (names resolved AS YOU, authorization pre-checked)
               --> confirmation  (you read the concrete mutation)
               --> Proposal.execute with YOU as the actor
               --> policies, then the audit log

  The model never holds the mutation. It returns a struct. That is a structural
  guarantee rather than a prompt instruction, which is what makes prompt
  injection uninteresting here: there is no tool to trick it into calling.

  Authorization is checked *before* the confirmation is rendered, so a proposal
  you could never perform is refused at the point of display. Asking someone to
  confirm an action that will then fail trains people to click through errors.

  See `docs/manifesto/05-agents-are-users.md`.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.AI.Interpreter
  alias AshEnterprise.AI.Proposal
  alias AshEnterprise.Security.ActorContext

  on_mount {AshEnterpriseWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:request, "")
     |> assign(:proposal, nil)
     |> assign(:error, nil)
     |> assign(:result, nil)
     |> assign(:thinking?, false)}
  end

  @impl true
  def handle_event("propose", %{"request" => request}, socket) do
    actor = socket.assigns.current_user
    tenant = tenant(socket)

    socket = assign(socket, request: request, error: nil, result: nil, proposal: nil)

    case Interpreter.interpret(request, actor, tenant) do
      {:ok, proposal} ->
        # Pre-flight the authorization so the confirmation is only ever shown
        # for something that can actually happen.
        case Proposal.authorize(proposal, actor, tenant) do
          :ok -> {:noreply, assign(socket, :proposal, proposal)}
          {:error, message} -> {:noreply, assign(socket, :error, message)}
        end

      {:error, message} ->
        {:noreply, assign(socket, :error, message)}
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

  # Not `current_user.organization_id`: `User` is `tenant?: false` and has no such
  # attribute, so the direct access raises `KeyError` the moment anyone submits a
  # request. The tenant comes off the context the plug already resolved.
  defp tenant(socket) do
    ActorContext.tenant(socket.assigns[:current_user])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-6 space-y-6">
      <header>
        <h1 class="text-2xl font-semibold">Helper</h1>
        <p class="text-base-content/70 text-sm">
          Ask for an administrative change. Nothing happens until you approve it.
        </p>
      </header>

      <form phx-submit="propose" class="join w-full">
        <input
          type="text"
          name="request"
          value={@request}
          placeholder="Assign the Administrator role to admin@example.com"
          class="input input-bordered join-item w-full"
          autocomplete="off"
        />
        <button type="submit" class="btn btn-primary join-item">Ask</button>
      </form>

      <div :if={@error} class="alert alert-error" role="alert">
        <span class="whitespace-pre-line">{@error}</span>
      </div>

      <div :if={@result} class="alert alert-success" role="status">
        <span>{@result}</span>
      </div>

      <%!--
        The confirmation. This is the human-in-the-loop step: the proposal is
        inert until "Approve" is pressed, and the mutation then runs with THIS
        user as the actor -- so the audit entry names the person who decided,
        not the model that suggested.
      --%>
      <div :if={@proposal} class="card border border-base-300 bg-base-100" data-role="proposal">
        <div class="card-body gap-4">
          <h2 class="card-title text-base">Confirm this change</h2>

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
              <dt class="text-base-content/60">{label |> to_string() |> String.capitalize()}</dt>
              <dd>{value}</dd>
            </div>
          </dl>

          <p class="text-base-content/60 text-xs">
            Runs as you, through the same permissions as the admin UI, and is recorded in the audit log.
          </p>

          <div class="card-actions justify-end">
            <button phx-click="reject" class="btn btn-ghost">Cancel</button>
            <button phx-click="approve" class="btn btn-primary" data-role="approve">Approve</button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
