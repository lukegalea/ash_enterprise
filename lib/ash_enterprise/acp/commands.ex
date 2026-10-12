defmodule AshEnterprise.Acp.Commands do
  @moduledoc """
  The ACP prompt grammar for the daily loop (Productivity OS dogfood, epic E6):
  which Ash action a prompt runs, and which A2UI surface the turn closes with.

  Every route is a declared action run by `ash_acp` as the session's actor with
  `authorize?: true`; the transcript gets the action's text, and the surface
  pane gets the same UI module the web page at `/app/<name>` serves, built for
  the same actor — one set of reads and policies, two renderings.

  | Prompt | Action | Surface |
  |---|---|---|
  | `today` | `Console.today` | `TodayUI` |
  | `brief` / `compose brief` — today has no brief | `MorningBrief.compose_today` | `TodayUI` |
  | `brief` / `compose brief` — today has one | `Console.today` | `TodayUI` |
  | `calendar [today\\|tomorrow\\|week\\|upcoming]` | `Console.agenda` | `CalendarUI`, that window |
  | `inbox` / `slack` | `Console.inbox` | `InboxUI` / `SlackUI` |
  | `people [search]` | `Console.people` | `PeopleUI`, searched |
  | `approvals` | `Console.approvals` | `ApprovalsUI` |
  | `approve N` / `reject N` / `approve brief` / `reject brief` | `HumanTask.approve` / `.reject` | `ApprovalsUI` |
  | `accounts` | `Console.accounts` | `AccountsUI` |
  | `sync calendar\\|gmail\\|slack` | `LinkedAccount.sync_now` | `AccountsUI` |
  | `erasure` | `Scope.scopes_digest` | `ErasureReadOnlyUI` — no shred over ACP |
  | any other surface's command, or `open <surface>` | `Console.open` | that surface's UI, if it has one |
  | `help` | `Console.help` | none |

  The surfaces, their commands and their doors come from the registry
  (`AshEnterprise.Surfaces`): a prompt that names a surface is matched there
  first (longest command or alias wins), and a surface whose door is closed
  for the actor is refused — the same door the web checks. What is left are
  the verbs: `brief`, `approve`, `reject`, `sync`, `help`.

  Decisions, syncs and composing a brief are consequential:
  `AshEnterprise.Acp.Approvals` turns them into `session/request_permission`
  (ADR 0015) before they run. Shred is not routable at all — it exists only
  on the web, behind a typed confirmation.
  """

  require Ash.Query

  alias AshEnterprise.Agents.Actions.ComposeToday
  alias AshEnterprise.Agents.{Console, MorningBrief}
  alias AshEnterprise.Bpmn.Actions.QueueDigest
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces
  alias AshEnterprise.Surfaces.Doors
  alias AshEnterpriseWeb.A2ui

  @windows %{
    "" => :today,
    "today" => :today,
    "tomorrow" => :tomorrow,
    "week" => :this_week,
    "this week" => :this_week,
    "upcoming" => :upcoming
  }

  @providers %{
    "calendar" => "google-calendar",
    "gmail" => "google-mail",
    "mail" => "google-mail",
    "slack" => "slack"
  }

  @typedoc "A routed prompt: the action spec ash_acp runs, and the surface to close the turn with."
  @type route :: %{spec: map(), surface: {module(), keyword()} | nil}

  @doc """
  Routes prompt text for `actor`. `{:error, reason}` when the prompt names
  nothing this grammar knows (the turn ends `refusal` with the reason).
  """
  @spec route(String.t(), term()) :: {:ok, route()} | {:error, String.t()}
  def route(text, actor) do
    tenant = ActorContext.tenant(actor)
    command = normalize(text)

    case Surfaces.match_command(String.replace_prefix(command, "open ", "")) do
      {surface, rest} -> open_route(surface, rest, actor, tenant)
      nil -> do_route(command, actor, tenant)
    end
  end

  @doc """
  The route that opens registry surface `key` for `actor`, with no further
  prompt text — what a direct "open this surface" request (an ACP extension
  method, a link) resolves to. Refused when the surface's door is closed.
  """
  @spec open(atom() | String.t(), term()) :: {:ok, route()} | {:error, String.t()}
  def open(key, actor) do
    case Surfaces.fetch(key) do
      nil -> {:error, "no surface named #{inspect(key)} — say `help` for yours"}
      surface -> open_route(surface, "", actor, ActorContext.tenant(actor))
    end
  end

  defp normalize(text) do
    text
    |> String.trim()
    |> String.trim_leading("/")
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  # Every registry surface opens here, behind its door: the door is the same
  # predicate the web's `SurfaceDoor` checks, so a surface closed on the web is
  # closed here too.
  defp open_route(surface, rest, actor, tenant) do
    if Surfaces.open?(surface, actor) do
      surface_route(surface.key, rest, surface, tenant)
    else
      {:error, "#{surface.label} is for #{Doors.audience(surface.door)}."}
    end
  end

  defp surface_route(:today, _rest, _surface, tenant),
    do: ok(Console, :today, %{}, "Today", tenant, {A2ui.TodayUI, []})

  defp surface_route(:calendar, rest, _surface, tenant) do
    case Map.fetch(@windows, rest) do
      {:ok, window} ->
        ok(
          Console,
          :agenda,
          %{window: window},
          "Calendar · #{window_label(window)}",
          tenant,
          {A2ui.CalendarUI, query_state: %{"preset" => to_string(window)}}
        )

      :error ->
        {:error, "calendar takes today, tomorrow, week or upcoming"}
    end
  end

  defp surface_route(:inbox, _rest, _surface, tenant),
    do: ok(Console, :inbox, %{system: :gmail}, "Inbox", tenant, {A2ui.InboxUI, []})

  defp surface_route(:slack, _rest, _surface, tenant),
    do: ok(Console, :inbox, %{system: :slack}, "Slack", tenant, {A2ui.SlackUI, []})

  defp surface_route(:people, search, _surface, tenant) do
    inputs = if search == "", do: %{}, else: %{search: search}
    query_state = if search == "", do: nil, else: %{"search" => search}

    ok(Console, :people, inputs, "People", tenant, {A2ui.PeopleUI, query_state: query_state})
  end

  defp surface_route(:approvals, _rest, _surface, tenant),
    do: ok(Console, :approvals, %{}, "Approvals", tenant, {A2ui.ApprovalsUI, []})

  defp surface_route(:accounts, _rest, _surface, tenant),
    do: ok(Console, :accounts, %{}, "Accounts & syncs", tenant, {A2ui.AccountsUI, []})

  defp surface_route(:erasure, _rest, surface, tenant),
    do: ok(Scope, :scopes_digest, %{}, "Erasure scopes", tenant, {Surfaces.acp_ui(surface), []})

  # Every other surface: `Console.open` says which (and, for a hand-written
  # page, where it lives on the web), and the pane shows its A2UI surface.
  defp surface_route(key, _rest, surface, tenant) do
    pane = if ui = Surfaces.acp_ui(surface), do: {ui, []}
    ok(Console, :open, %{surface: Atom.to_string(key)}, surface.label, tenant, pane)
  end

  # The verbs: prompts that are not a surface.
  defp do_route(command, actor, tenant)

  # "My brief": compose today's when there is none, otherwise show the day.
  # There is no recompose (one brief per day), so neither spelling asks
  # permission for a compose that would only report the brief that exists.
  defp do_route(command, actor, tenant)
       when command in ["brief", "compose brief", "compose", "brief compose"] do
    case ComposeToday.existing(LocalTime.today(), actor, actor: actor, tenant: tenant) do
      {:ok, nil} -> compose_brief(tenant)
      _brief_or_unreadable -> ok(Console, :today, %{}, "Today", tenant, {A2ui.TodayUI, []})
    end
  end

  defp do_route("approve " <> which, actor, tenant), do: decide(:approve, which, actor, tenant)
  defp do_route("reject " <> which, actor, tenant), do: decide(:reject, which, actor, tenant)
  defp do_route("sync " <> provider, actor, tenant), do: sync(provider, actor, tenant)

  defp do_route(command, _actor, tenant) when command in ["help", "?", "commands"] do
    ok(Console, :help, %{}, "Help", tenant, nil)
  end

  defp do_route("list business units", _actor, tenant) do
    {:ok,
     %{
       spec: %{
         resource: AshEnterprise.Accounts.BusinessUnit,
         action: :read,
         label: "List business units",
         tenant: tenant
       },
       surface: :business_units
     }}
  end

  defp do_route(_command, _actor, _tenant),
    do: {:error, "unknown command — say `help` for the list"}

  # A write (it opens a brief and starts its process), so it is consequential
  # and asks first; a day that already has one answers with that instead.
  defp compose_brief(tenant) do
    ok(MorningBrief, :compose_today, %{}, "Compose today's brief", tenant, {A2ui.TodayUI, []},
      kind: :execute
    )
  end

  # `approve 2` / `reject brief`: the target is resolved as the actor, from
  # the same read the `approvals` list shows (so the number is the one they
  # saw), and the decision runs only after the permission request is allowed.
  defp decide(verb, which, actor, tenant) do
    opts = [actor: actor, tenant: tenant]

    with {:ok, task, label} <- decision_target(String.trim(which), opts) do
      title = "#{if(verb == :approve, do: "Approve", else: "Reject")}: #{label}"

      ok(HumanTask, verb, %{record_id: task.id}, title, tenant, {A2ui.ApprovalsUI, []},
        kind: :execute
      )
    end
  end

  defp decision_target("brief", opts) do
    with {:ok, %MorningBrief{} = brief} <- AshEnterprise.Agents.Today.latest_brief(opts),
         {:ok, task} <- AshEnterprise.Agents.BriefDecision.open_task(brief, opts) do
      {:ok, task, "Morning brief · #{LocalTime.day(brief.brief_date)}"}
    else
      _ -> {:error, "no morning brief is waiting on you"}
    end
  end

  defp decision_target(number, opts) do
    with {n, ""} when n > 0 <- Integer.parse(number),
         {:ok, tasks} <- QueueDigest.awaiting(opts),
         %{} = task <- Enum.at(tasks, n - 1) do
      {:ok, task, "##{n} #{task.subject_label || task.name}"}
    else
      _ -> {:error, "no approval ##{number} — say `approvals` to list them"}
    end
  end

  defp sync(provider, actor, tenant) do
    with {:ok, key} <- Map.fetch(@providers, String.trim(provider)),
         {:ok, [account | _]} <-
           LinkedAccount
           |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)
           |> Ash.Query.filter(provider_config_key == ^key and lifecycle_status == :active)
           |> Ash.read(actor: actor, tenant: tenant) do
      label = AshEnterprise.Integration.Calculations.AccountHealth.provider(key)

      ok(
        LinkedAccount,
        :sync_now,
        %{record_id: account.id},
        "Sync now: #{label}",
        tenant,
        {A2ui.AccountsUI, []},
        kind: :execute
      )
    else
      :error -> {:error, "sync takes calendar, gmail or slack"}
      _ -> {:error, "no active linked account for #{String.trim(provider)}"}
    end
  end

  defp ok(resource, action, inputs, title, tenant, surface, extra \\ []) do
    {:ok,
     %{
       spec: %{
         resource: resource,
         action: action,
         inputs: inputs,
         title: title,
         kind: Keyword.get(extra, :kind, :read),
         tenant: tenant
       },
       surface: surface
     }}
  end

  defp window_label(:today), do: "today"
  defp window_label(:tomorrow), do: "tomorrow"
  defp window_label(:this_week), do: "this week"
  defp window_label(:upcoming), do: "next two weeks"

  @doc """
  The actions ACP treats as consequential: each becomes a
  `session/request_permission` before it runs, even when policy allows it
  (dogfood §5 — every consequential action is an approval).
  """
  @spec consequential?(module(), atom()) :: boolean()
  def consequential?(HumanTask, action) when action in [:approve, :reject], do: true
  def consequential?(LinkedAccount, :sync_now), do: true
  def consequential?(MorningBrief, :compose_today), do: true
  def consequential?(_resource, _action), do: false

  @doc """
  The command list as text, pruned to what `actor` may run (`help`): the
  palette (`AshEnterprise.Surfaces.candidate_actions/0`, pruned with
  `Ash.can?/3`), then every other surface whose door is open for them.
  """
  @spec help(term()) :: String.t()
  def help(actor) do
    commands =
      AshAcp.AvailableActions.for_actor(actor, Surfaces.candidate_actions(),
        tenant: ActorContext.tenant(actor)
      )

    lines =
      Enum.map(commands, fn command ->
        hint =
          case command do
            %{"input" => %{"hint" => hint}} -> " " <> hint
            _ -> ""
          end

        "  #{command["name"]}#{hint} — #{command["description"]}"
      end)

    surfaces =
      for group <- Surfaces.grouped(actor),
          words = for(%{acp: %{command: c} = acp} <- group.surfaces, !acp[:palette?], do: c),
          words != [],
          do: "  #{group.label}: #{Enum.join(words, ", ")}"

    Enum.join(
      ["Commands (what your access allows):" | lines] ++
        ["", "Surfaces (say the name, or `open <name>`):" | surfaces],
      "\n"
    )
  end
end
