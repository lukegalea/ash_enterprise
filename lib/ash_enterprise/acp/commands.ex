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
  | `calendar [today\\|tomorrow\\|week\\|upcoming]` | `Console.agenda` | `CalendarUI`, that window |
  | `inbox` / `slack` | `Console.inbox` | `InboxUI` / `SlackUI` |
  | `people [search]` | `Console.people` | `PeopleUI`, searched |
  | `approvals` | `Console.approvals` | `ApprovalsUI` |
  | `approve N` / `reject N` / `approve brief` / `reject brief` | `HumanTask.approve` / `.reject` | `ApprovalsUI` |
  | `accounts` | `Console.accounts` | `AccountsUI` |
  | `sync calendar\\|gmail\\|slack` | `LinkedAccount.sync_now` | `AccountsUI` |
  | `erasure` | `Scope.scopes_digest` | `ErasureReadOnlyUI` — no shred over ACP |
  | `help` | `Console.help` | none |

  Decisions and syncs are consequential: `AshEnterprise.Acp.Approvals` turns
  them into `session/request_permission` (ADR 0015) before they run. Shred is
  not routable at all — it exists only on the web, behind a typed
  confirmation.
  """

  require Ash.Query

  alias AshEnterprise.Agents.{Console, MorningBrief}
  alias AshEnterprise.Bpmn.Actions.QueueDigest
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Security.ActorContext
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

    text
    |> normalize()
    |> do_route(actor, tenant)
  end

  defp normalize(text) do
    text
    |> String.trim()
    |> String.trim_leading("/")
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  defp do_route(command, actor, tenant)

  defp do_route(command, _actor, tenant) when command in ["today", "brief", "day"] do
    ok(Console, :today, %{}, "Today", tenant, {A2ui.TodayUI, []})
  end

  defp do_route("calendar" <> rest, _actor, tenant) do
    case Map.fetch(@windows, String.trim(rest)) do
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

  defp do_route(command, _actor, tenant) when command in ["inbox", "mail", "gmail"] do
    ok(Console, :inbox, %{system: :gmail}, "Inbox", tenant, {A2ui.InboxUI, []})
  end

  defp do_route("slack", _actor, tenant) do
    ok(Console, :inbox, %{system: :slack}, "Slack", tenant, {A2ui.SlackUI, []})
  end

  defp do_route("people" <> rest, _actor, tenant) do
    search = String.trim(rest)
    inputs = if search == "", do: %{}, else: %{search: search}
    query_state = if search == "", do: nil, else: %{"search" => search}

    ok(
      Console,
      :people,
      inputs,
      "People",
      tenant,
      {A2ui.PeopleUI, query_state: query_state}
    )
  end

  defp do_route(command, _actor, tenant) when command in ["approvals", "tasks"] do
    ok(Console, :approvals, %{}, "Approvals", tenant, {A2ui.ApprovalsUI, []})
  end

  defp do_route("approve " <> which, actor, tenant), do: decide(:approve, which, actor, tenant)
  defp do_route("reject " <> which, actor, tenant), do: decide(:reject, which, actor, tenant)

  defp do_route(command, _actor, tenant) when command in ["accounts", "syncs", "sync status"] do
    ok(Console, :accounts, %{}, "Accounts & syncs", tenant, {A2ui.AccountsUI, []})
  end

  defp do_route("sync " <> provider, actor, tenant), do: sync(provider, actor, tenant)

  defp do_route(command, _actor, tenant)
       when command in ["erasure", "scopes", "erasure scopes"] do
    ok(
      Scope,
      :scopes_digest,
      %{},
      "Erasure scopes",
      tenant,
      {A2ui.ErasureReadOnlyUI, []}
    )
  end

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
      {:ok, task, "Morning brief · #{AshEnterprise.Platform.LocalTime.day(brief.brief_date)}"}
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
  def consequential?(_resource, _action), do: false

  @doc "The command list as text, pruned to what `actor` may run (`help`)."
  @spec help(term()) :: String.t()
  def help(actor) do
    commands =
      AshAcp.AvailableActions.for_actor(
        actor,
        Application.get_env(:ash_acp, :candidate_actions, []),
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

    Enum.join(["Commands (what your access allows):" | lines], "\n")
  end
end
