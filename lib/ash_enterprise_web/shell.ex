defmodule AshEnterpriseWeb.Shell do
  @moduledoc """
  The web's command palette (ctrl+p) and surface launcher (ctrl+k): the
  host half of `AshA2ui.Shell.Component`, which the app layout mounts on
  every page (`AshEnterpriseWeb.Layouts.app/1`).

  ## The same lists as the terminal

  Amber and any other ACP client get their palette and launcher from this
  server, and so does the web, from the same functions:

    * **commands** — `AshEnterprise.Surfaces.candidate_actions/0`, pruned
      for the person by `AshAcp.AvailableActions.for_actor/3` exactly as ACP
      prunes the `available_commands_update` it sends;
    * **surfaces** — `AshEnterprise.Acp.ExtMethods.entries/2`, the
      `_ash/surfaces/list` entries, with the web's hand-written pages kept
      (`:web`): the agent, flights, lineage, audit, time travel.

  Both read the surfaces' doors and policies as the person, so neither the
  palette nor the launcher offers something they could not open. Each open
  checks the door again (`AshEnterprise.Surfaces.Records`), because a list
  read when the shell opened can be older than a role change.

  The lists are read when the shell first opens on a page, not on mount.

  ## What each invocation does

  | Invocation | Web |
  |---|---|
  | open a surface | navigate to its page |
  | `/open <surface> <id>` | `/app/r/<surface>/<id>`, the deep link (re-authorized there) |
  | `/open <surface> <n>` | `/app/r/<surface>/row/<n>`, the `n`th row as the person reads it |
  | a command that names a surface (`/calendar`, `/approvals`) | that surface's page |
  | `/help` | the launcher page, which lists everything |
  | any other command, or a command with words after it (`/approve 2`, `/calendar week`) | the agent, as a prompt |
  | a typed line | the agent at `/app/agent`, as a prompt |

  A prompt travels as an `AshEnterpriseWeb.AssistantHandoff` token: the
  person's words never sit in the URL in the clear, and only they can ask
  it. The agent asks before it changes anything, so a verb such as
  `/approve` reaches a decision only through its confirmation.
  """

  @behaviour AshA2ui.Shell.Host

  use AshEnterpriseWeb, :verified_routes

  alias AshEnterprise.Acp.ExtMethods
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces
  alias AshEnterprise.Surfaces.{Records, Surface}
  alias AshEnterpriseWeb.AssistantHandoff
  alias Phoenix.LiveView

  @impl true
  def entries(nil), do: %{commands: [], surfaces: []}
  def entries(actor), do: %{commands: commands(actor), surfaces: surfaces(actor)}

  @doc "The palette's commands for `actor`: ACP's, pruned the way ACP prunes them."
  @spec commands(term()) :: [map()]
  def commands(nil), do: []

  def commands(actor) do
    AshAcp.AvailableActions.for_actor(actor, Surfaces.candidate_actions(),
      tenant: ActorContext.tenant(actor)
    )
  end

  @doc "The launcher's surfaces for `actor`: `_ash/surfaces/list`'s, with the web's own pages."
  @spec surfaces(term()) :: [map()]
  def surfaces(actor), do: ExtMethods.entries(actor, :web)

  @impl true
  def invoke({:open_surface, %{"id" => id}, target}, actor, socket) do
    with {:ok, surface} <- Records.surface_for(id, actor),
         true <- Surfaces.readable?(surface, actor) do
      {:ok, open(socket, surface, target)}
    else
      {:error, error} -> {:error, Records.message(error)}
      false -> {:error, "That surface is not open to you."}
    end
  end

  def invoke({:command, %{"name" => "help"}, []}, _actor, socket),
    do: {:ok, LiveView.push_navigate(socket, to: ~p"/app")}

  def invoke({:command, %{"name" => name}, args}, actor, socket) do
    case {Surfaces.match_command(name), args} do
      {{%Surface{key: key}, ""}, []} ->
        invoke({:open_surface, %{"id" => to_string(key)}, nil}, actor, socket)

      _verb_or_words ->
        invoke({:prompt, Enum.join([name | args], " ")}, actor, socket)
    end
  end

  def invoke({:prompt, text}, actor, socket) do
    {:ok,
     LiveView.push_navigate(socket,
       to: ~p"/app/agent?#{[ask: AssistantHandoff.token(actor, text)]}"
     )}
  end

  # The launcher is the component's own mode; nothing to do here.
  def invoke(:launcher, _actor, socket), do: {:ok, socket}

  # A page in another live_session is a full navigation either way;
  # push_navigate falls back to one. The deep links are controller
  # redirects, so those are plain redirects.
  defp open(socket, surface, nil), do: LiveView.push_navigate(socket, to: surface.path)

  defp open(socket, surface, {:record, id}),
    do: LiveView.redirect(socket, to: ~p"/app/r/#{surface.key}/#{id}")

  defp open(socket, surface, {:nth, n}),
    do: LiveView.redirect(socket, to: ~p"/app/r/#{surface.key}/row/#{n}")
end
