defmodule AshEnterprise.Acp.Commands do
  @moduledoc """
  The ACP prompt grammar for the daily loop:
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
  | `ask N <question>` — ask the requester before deciding | `HumanTask.request_info` | `ApprovalsUI` |
  | `answer N <text>` — a question you were asked | `HumanTask.answer` | `ApprovalsUI` |
  | `retry <invocation id> <reason>` | `Intervention.rerun` | none |
  | `cancel <invocation id> <reason>` | `Intervention.cancel` | none |
  | `reconcile <invocation id> succeeded\|failed\|retry <reason>` | `Intervention.resolve` | none |
  | `publish <agent version id>` | `AgentVersion.request_publish` | none |
  | `release <manifest id>` — ask to promote it | `ReleaseManifest.request_release` | none |
  | `grant <role name> to <email>` — ask for a role assignment | `UserRole.request_assignment` | none |
  | `accounts` | `Console.accounts` | `AccountsUI` |
  | `sync calendar\\|gmail\\|slack` | `LinkedAccount.sync_now` | `AccountsUI` |
  | `erasure` | `Scope.scopes_digest` | `ErasureReadOnlyUI` — no shred over ACP |
  | `todo` / `todos` / `action items` | `Console.action_items` | `ActionItemsUI` |
  | `todo <text>` | `Console.todo` — captured into the actor's Inbox | `ActionItemsUI` |
  | `done N` | `Console.done` — the Nth item of the `todo` list | `ActionItemsUI` |
  | any other surface's command, or `open <surface>` | `Console.open` | that surface's UI, if it has one |
  | `open <surface> <id>` / `open <surface> <n>` | `Console.open` | that surface with the record (by id, or the nth row) selected |
  | `help` | `Console.help` | none |

  The surfaces, their commands and their doors come from the registry
  (`AshEnterprise.Surfaces`): a prompt that names a surface is matched there
  first (longest command or alias wins), and a surface whose door is closed
  for the actor is refused — the same door the web checks. What is left are
  the verbs: `brief`, `approve`, `reject`, `ask`, `answer`, `retry`, `cancel`,
  `reconcile`, `publish`, `release`, `sync`, `done`, `help`. `verbs/0` lists each
  with the action it runs, so a channel-parity check reads them from here.

  The verbs that carry a person's words (`ask`, `answer`, `retry`, `cancel`,
  `reconcile`) keep them as typed, as `todo <text>` does; none needs a model to
  read the prompt.

  Each routed action's `AshAgent.Effects` declaration (ADR 0057) says what it
  does: its ACP tool kind, and whether it asks first. Decisions, syncs and
  composing a brief declare `approval: :confirm`, so they are routed as a
  request: the spec runs `Invocation.confirm` for the action, under the key
  `AshEnterprise.Acp.Approvals.key/4` finds or makes, and
  `AshEnterprise.Acp.Approvals` records it as an invocation waiting on the
  person and asks them through `session/request_permission` (ADR 0015, ADR
  0055) before it runs. Capturing and finishing one's own action item
  declare `approval: :none`: each is the person's own act on their own row,
  and undone from the board (Drop, Reopen). Shred is not routable at all — it
  exists only on the web, behind a typed confirmation.

  `todo <text>` keeps the text as typed (the rest of the grammar matches on a
  lower-cased prompt), so an action item reads the way it was said.
  """

  require Ash.Query

  alias AshEnterprise.Acp
  alias AshEnterprise.Acp.Approvals
  alias AshEnterprise.Agents.Actions.ComposeToday
  alias AshEnterprise.Agents.{Console, MorningBrief}
  alias AshEnterprise.Bpmn.Actions.QueueDigest
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Canonical.Actions.ActionItemsDigest
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Execution.{AgentVersion, Intervention, Invocation, ReleaseManifest}
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces
  alias AshEnterprise.Surfaces.{Doors, Records}
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

  @verbs [
    %{verb: "approve N", resource: HumanTask, action: :approve},
    %{verb: "reject N", resource: HumanTask, action: :reject},
    %{verb: "ask N <question>", resource: HumanTask, action: :request_info},
    %{verb: "answer N <text>", resource: HumanTask, action: :answer},
    %{verb: "retry <invocation id> <reason>", resource: Intervention, action: :rerun},
    %{verb: "cancel <invocation id> <reason>", resource: Intervention, action: :cancel},
    %{
      verb: "reconcile <invocation id> succeeded|failed|retry <reason>",
      resource: Intervention,
      action: :resolve
    },
    %{verb: "publish <agent version id>", resource: AgentVersion, action: :request_publish},
    %{verb: "release <manifest id>", resource: ReleaseManifest, action: :request_release},
    %{
      verb: "grant <role name> to <email>",
      resource: AshEnterprise.Security.UserRole,
      action: :request_assignment
    },
    %{verb: "brief", resource: MorningBrief, action: :compose_today},
    %{verb: "sync calendar|gmail|slack", resource: LinkedAccount, action: :sync_now},
    %{verb: "todo <text>", resource: Console, action: :todo},
    %{verb: "done N", resource: Console, action: :done}
  ]

  @doc """
  The verbs this grammar routes to an act, each with the resource and action it runs:
  what a channel-parity check reads (`test/ash_enterprise/channels/parity_test.exs`).
  """
  @spec verbs() :: [%{verb: String.t(), resource: module(), action: atom()}]
  def verbs, do: @verbs

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
    open? = String.starts_with?(command, "open ")

    case {capture_text(text), worded(text)} do
      {{:ok, title}, _worded} -> capture(title, actor, tenant)
      {:none, {:grant, role, email}} -> grant(role, email, actor, tenant)
      {:none, {verb, target, words}} -> worded_route(verb, target, words, actor, tenant)
      {:none, :none} -> route_command(command, open?, actor, tenant)
    end
  end

  # The verbs that carry a person's words, as typed: `{verb, target, words}`.
  @worded ~w(ask answer retry cancel reconcile)

  defp worded(text) do
    case Regex.run(~r/^\/?grant\s+(.+?)\s+to\s+(\S+@\S+)$/iu, String.trim(text)) do
      [_, role, email] -> {:grant, String.trim(role), email}
      nil -> worded_verb(text)
    end
  end

  defp worded_verb(text) do
    case Regex.run(~r/^\/?(\w+)\s+(\S+)\s+(.+)$/su, String.trim(text)) do
      [_, verb, target, words] ->
        verb = String.downcase(verb)
        if verb in @worded, do: {verb, target, String.trim(words)}, else: :none

      nil ->
        :none
    end
  end

  # `ask 2 <question>` / `answer 2 <text>`: the task is the one the `approvals` list
  # numbers, read as the actor.
  defp worded_route(verb, number, words, actor, tenant) when verb in ["ask", "answer"] do
    {action, inputs, title} =
      case verb do
        "ask" -> {:request_info, %{question: words}, "Ask for more information"}
        "answer" -> {:answer, %{answer: words}, "Answer"}
      end

    with {:ok, task, label} <- decision_target(number, actor: actor, tenant: tenant) do
      ask(
        HumanTask,
        action,
        Map.put(inputs, :record_id, task.id),
        "#{title}: #{label}",
        {actor, tenant},
        {A2ui.ApprovalsUI, []}
      )
    end
  end

  # The recovery acts, on an invocation named by its id (the recovery surface's own
  # address for it): each says why.
  defp worded_route("reconcile", id, words, actor, tenant) do
    case String.split(words, ~r/\s+/u, parts: 2) do
      [resolution, reason] when resolution in ~w(succeeded failed retry) ->
        recover(:resolve, id, %{resolution: resolution, reason: reason}, actor, tenant)

      _other ->
        {:error, "reconcile takes an invocation id, succeeded, failed or retry, and why"}
    end
  end

  defp worded_route(verb, id, reason, actor, tenant) do
    act = if verb == "retry", do: :rerun, else: :cancel
    recover(act, id, %{reason: reason}, actor, tenant)
  end

  defp recover(act, id, inputs, actor, tenant) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        ask(
          Intervention,
          act,
          Map.put(inputs, :invocation_id, id),
          "#{String.capitalize(to_string(act))} invocation #{String.slice(id, 0, 8)}",
          {actor, tenant},
          nil
        )

      :error ->
        {:error, "name the invocation by its id"}
    end
  end

  defp route_command(command, open?, actor, tenant) do
    case Surfaces.match_command(String.replace_prefix(command, "open ", "")) do
      {surface, rest} ->
        case record_ref(rest, open?) do
          nil -> open_route(surface, rest, actor, tenant)
          ref -> record_route(surface, ref, actor, tenant)
        end

      nil ->
        do_route(command, actor, tenant)
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

  # `open <surface> <id>` (any spelling, any surface) or `open <surface> <n>`
  # — the nth row of the surface as the actor sees it. A bare number without
  # `open` stays the surface's own argument (`people 2` searches for "2").
  defp record_ref(rest, open?) do
    cond do
      Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, rest) ->
        {:id, rest}

      open? and Regex.match?(~r/^#?[1-9][0-9]*$/, rest) ->
        {:nth, rest |> String.trim_leading("#") |> String.to_integer()}

      true ->
        nil
    end
  end

  # One record on its surface, re-authorized as the actor
  # (`AshEnterprise.Surfaces.Records`): the pane shows the surface with it
  # selected. A surface with no detail opens as itself.
  defp record_route(surface, {:nth, n}, actor, tenant) do
    case nth_id(surface, n, actor, tenant) do
      {:ok, id} -> record_route(surface, {:id, id}, actor, tenant)
      :error -> {:error, "no row #{n} on #{surface.label}"}
    end
  end

  defp record_route(surface, {:id, id}, actor, tenant) do
    case Records.open(surface.key, id, actor) do
      {:ok, %{surface: home, context_state: state}} ->
        ok(
          Console,
          :open,
          %{surface: Atom.to_string(home.key)},
          home.label,
          tenant,
          {Surfaces.acp_ui(home), context_state: state}
        )

      {:error, {:no_detail, _surface}} ->
        open_route(surface, "", actor, tenant)

      {:error, error} ->
        {:error, Records.message(error)}
    end
  end

  # The nth row of the surface's first table, read exactly as its pane would
  # show it (the surface's own read, query defaults and policies).
  defp nth_id(%{ui: nil}, _n, _actor, _tenant), do: :error

  defp nth_id(surface, n, actor, tenant) do
    model =
      surface
      |> Surfaces.acp_ui()
      |> AshA2ui.Info.build_data_model(actor: actor, tenant: tenant)
      |> get_in(["updateDataModel", "value"])

    rows =
      case model && model["records"] do
        rows when is_list(rows) -> rows
        %{"table" => rows} when is_list(rows) -> rows
        _other -> []
      end

    case Enum.at(rows, n - 1) do
      %{"id" => id} when is_binary(id) -> {:ok, id}
      _none -> :error
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
          # Calendar is multi-table (the agenda and an event's attendees), so
          # its query state is keyed by table.
          {A2ui.CalendarUI, query_state: %{"table" => %{"preset" => to_string(window)}}}
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
    # People is multi-table (the directory and a person's related tables).
    query_state = if search == "", do: nil, else: %{"table" => %{"search" => search}}

    ok(Console, :people, inputs, "People", tenant, {A2ui.PeopleUI, query_state: query_state})
  end

  defp surface_route(:approvals, _rest, _surface, tenant),
    do: ok(Console, :approvals, %{}, "Approvals", tenant, {A2ui.ApprovalsUI, []})

  defp surface_route(:accounts, _rest, _surface, tenant),
    do: ok(Console, :accounts, %{}, "Accounts & syncs", tenant, {A2ui.AccountsUI, []})

  # `todo <text>` never gets here (`capture_text/1` takes it first), so any
  # rest is not an item to capture: the list opens.
  defp surface_route(:action_items, _rest, _surface, tenant),
    do: ok(Console, :action_items, %{}, "Action items", tenant, {A2ui.ActionItemsUI, []})

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
      {:ok, nil} -> compose_brief(actor, tenant)
      _brief_or_unreadable -> ok(Console, :today, %{}, "Today", tenant, {A2ui.TodayUI, []})
    end
  end

  defp do_route("approve " <> which, actor, tenant), do: decide(:approve, which, actor, tenant)
  defp do_route("reject " <> which, actor, tenant), do: decide(:reject, which, actor, tenant)
  defp do_route("sync " <> provider, actor, tenant), do: sync(provider, actor, tenant)

  defp do_route("publish " <> id, actor, tenant),
    do: request(AgentVersion, :request_publish, id, "Ask to publish", {actor, tenant})

  defp do_route("release " <> id, actor, tenant),
    do: request(ReleaseManifest, :request_release, id, "Ask to release", {actor, tenant})

  defp do_route("done " <> which, actor, tenant), do: finish(String.trim(which), actor, tenant)

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

  # A write (it opens a brief and starts its process), so it declares
  # `approval: :confirm` and asks first; a day that already has one answers
  # with that instead.
  defp compose_brief(actor, tenant) do
    ask(MorningBrief, :compose_today, %{}, "Compose today's brief", {actor, tenant}, {
      A2ui.TodayUI,
      []
    })
  end

  # `approve 2` / `reject brief`: the target is resolved as the actor, from
  # the same read the `approvals` list shows (so the number is the one they
  # saw), and the decision runs only after the permission request is allowed.
  defp decide(verb, which, actor, tenant) do
    opts = [actor: actor, tenant: tenant]

    with {:ok, task, label} <- decision_target(String.trim(which), opts) do
      title = "#{if(verb == :approve, do: "Approve", else: "Reject")}: #{label}"

      ask(HumanTask, verb, %{record_id: task.id}, title, {actor, tenant}, {A2ui.ApprovalsUI, []})
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

  # `todo <text>` (or `to do <text>`), as typed: `{:ok, text}`, else `:none`.
  # `todo list` names the list, not an item.
  defp capture_text(text) do
    case Regex.run(~r/^\/?(?:todo|to do)\s+(.+)$/iu, String.trim(text)) do
      [_, rest] ->
        rest = rest |> String.replace(~r/\s+/u, " ") |> String.trim()
        if String.downcase(rest) == "list", do: :none, else: {:ok, rest}

      nil ->
        :none
    end
  end

  # Behind the surface's door, like opening it: the capture is the actor's
  # own `Task.capture`, run by `Console.todo` as them.
  defp capture(title, actor, tenant) do
    surface = Surfaces.fetch!(:action_items)

    if Surfaces.open?(surface, actor) do
      ok(
        Console,
        :todo,
        %{text: title},
        "Capture: #{String.slice(title, 0, 60)}",
        tenant,
        {A2ui.ActionItemsUI, []}
      )
    else
      {:error, "#{surface.label} is for #{Doors.audience(surface.door)}."}
    end
  end

  # `done 2`: resolved as the actor from the same list `todo` shows, so the
  # number is the one they saw.
  defp finish(number, actor, tenant) do
    opts = [actor: actor, tenant: tenant, authorize?: true]

    with {n, ""} when n > 0 <- Integer.parse(String.trim_leading(number, "#")),
         {:ok, items} <- ActionItemsDigest.items(opts),
         %Task{} = task <- Enum.at(items, n - 1) do
      ok(
        Console,
        :done,
        %{record_id: task.id},
        "Done: ##{n} #{String.slice(task.label, 0, 60)}",
        tenant,
        {A2ui.ActionItemsUI, []}
      )
    else
      _ -> {:error, "no action item ##{number} — say `todo` to list them"}
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

      ask(
        LinkedAccount,
        :sync_now,
        %{record_id: account.id},
        "Sync now: #{label}",
        {actor, tenant},
        {A2ui.AccountsUI, []}
      )
    else
      :error -> {:error, "sync takes calendar, gmail or slack"}
      _ -> {:error, "no active linked account for #{String.trim(provider)}"}
    end
  end

  # `grant Clinic lead to dana@clinic.example`: the names resolved as the actor, the way
  # the agent console resolves the ones its model reads (`Interpreter.plan/5`, the seam
  # below the model), then the request door, which waits for another administrator.
  defp grant(role, email, actor, tenant) do
    intent = %AshEnterprise.AI.Intent{kind: :assign_role, role_name: role, user_email: email}

    case AshEnterprise.AI.Interpreter.plan(intent, "", actor, tenant) do
      {:ok, {:role_request, request}} ->
        resource = AshEnterprise.Security.UserRole
        route = if Acp.asks_first?(resource, :request_assignment), do: &ask/6, else: &ok_as/6

        route.(
          resource,
          :request_assignment,
          %{user_id: request.user_id, role_id: request.role_id},
          "Ask to grant #{request.role} to #{request.user}",
          {actor, tenant},
          nil
        )

      {:error, message} ->
        {:error, message}
    end
  end

  # A request door (`publish`, `release`): it asks for a governed act that waits on a
  # second person, so it runs as itself, and its result is pending.
  defp request(resource, action, id, title, {actor, tenant}) do
    case Ecto.UUID.cast(String.trim(id)) do
      {:ok, id} ->
        route = if Acp.asks_first?(resource, action), do: &ask/6, else: &ok_as/6

        route.(
          resource,
          action,
          %{record_id: id},
          "#{title} #{String.slice(id, 0, 8)}",
          {actor, tenant},
          nil
        )

      :error ->
        {:error, "name it by its id"}
    end
  end

  defp ok_as(resource, action, inputs, title, {_actor, tenant}, surface),
    do: ok(resource, action, inputs, title, tenant, surface)

  # ash_acp names the route's tool kind through the host's kind resolver
  # (`Acp.kind/2`, the action's effects declaration).
  defp ok(resource, action, inputs, title, tenant, surface) do
    {:ok,
     %{
       spec: %{
         resource: resource,
         action: action,
         inputs: inputs,
         title: title,
         tenant: tenant
       },
       surface: surface
     }}
  end

  # An action whose declaration asks first is routed as a request of it: the spec
  # confirms an invocation of the action (`Invocation.confirm`), so the permission
  # request is a durable row and the action runs once, through it.
  defp ask(resource, action, inputs, title, {actor, tenant}, surface) do
    target = AshAgent.Invocation.Target.name(resource, action)
    args = Map.new(inputs, fn {name, value} -> {to_string(name), value} end)

    {:ok,
     %{
       spec: %{
         resource: Invocation,
         action: :confirm,
         inputs: %{target: target, args: args, key: Approvals.key(actor, target, args, tenant)},
         title: title,
         kind: Acp.kind(resource, action),
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
