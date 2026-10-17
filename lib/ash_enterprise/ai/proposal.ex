defmodule AshEnterprise.AI.Proposal do
  @moduledoc """
  A mutation an agent has proposed but **not** performed.

  This is the mechanism behind the human-in-the-loop half of
  `docs/manifesto/05-agents-are-users.md`. Policies answer *may this actor do
  this*; they cannot answer *did this actor actually ask for this*. Those differ
  precisely when a model is interpreting natural language, and the gap is where
  the confident-but-wrong mutation lives.

  So the model never holds the tool. It **plans**; the human **approves**; the
  application **executes**. A proposal is inert data until `execute/2` is called
  with a human's actor.

  ## Why this is not just "call the tool and show a diff"

  Two properties fall out of separating the plan from the execution:

    * The proposal can be **authorization-checked before it is shown**.
      `authorize/2` runs `Ash.can?` with the requesting human's actor, so a
      proposal the user could never perform is rejected at the point of display
      rather than after they approve it. Asking someone to confirm an action
      that will then fail is a bad experience and trains people to click through
      errors.
    * Execution is ordinary Ash code with the **human** as the actor. The audit
      entry therefore records the person who approved, not the agent — which is
      the truthful attribution, because the person is who decided.

  ## Deliberately narrow

  Only mutations the platform explicitly models as proposable can be built here.
  There is no generic "run this action with these params" constructor: that
  would make the safety of the flow depend on the model's choice of action name,
  which is exactly the property we are trying not to rely on.

  The proposable mutations, each with its own constructor that resolves the
  names a person (or a model) used **as that person**:

  | Kind | Constructor | Runs |
  |---|---|---|
  | `:assign_role` | `assign_role/4` | `Security.UserRole.assign` |
  | `:create_task` | `create_task/4` | `Canonical.Task.capture` |
  | `:complete_task` | `complete_task/3` | `Canonical.Task.complete_mine` |
  | `:draft_reply` | `draft_reply/4` | `Assistant.ReplyDraft.draft` (stored, never sent) |
  | `:sync_now` | `sync_now/3` | `Integration.LinkedAccount.sync_now`, per account |

  ## Decisions are not proposable here

  Approving or rejecting a morning brief or a process task, and a steward's
  confirm or reject, are **decisions**, and who may make one is the process
  engine's question (the who-acts check on a human task), not a role grant's.
  `decision/4` is the seam: it refuses, naming why, until decisions are routed
  through that check.

  ## Wire form

  A proposal built for the agent chat travels between the model, the runner
  and the page as `to_wire/1` — the kind and the resolved ids, nothing else —
  and is rebuilt by `from_wire/3` as the confirming person before it is shown
  and again before it runs. The page never executes what the model wrote; it
  executes what resolving the model's request *as the person* produced.
  """

  @enforce_keys [:kind, :summary, :resource, :action, :params]
  defstruct [:kind, :summary, :resource, :action, :params, :details]

  @type t :: %__MODULE__{
          kind: atom(),
          summary: String.t(),
          resource: module(),
          action: atom(),
          params: map(),
          details: keyword()
        }

  alias AshEnterprise.Accounts
  alias AshEnterprise.Assistant.ReplyDraft
  alias AshEnterprise.Canonical.{Conversation, Task}
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Security

  require Ash.Query

  @decisions [:decide_brief, :decide_task, :steward_verdict]

  # The names a person uses for an integration, and its provider config key.
  @providers %{"gmail" => "google-mail", "calendar" => "google-calendar", "slack" => "slack"}

  @doc """
  Builds a role-assignment proposal from names a human would use.

  Resolution runs **as the requesting actor**, so a user who cannot see a given
  user or role gets "not found" rather than a proposal referencing a record they
  have no business knowing exists. That is the same reasoning as Ash filtering
  reads instead of forbidding them.
  """
  def assign_role(actor, tenant, user_email, role_name) do
    with {:ok, user} <- find_user(actor, tenant, user_email),
         {:ok, role} <- find_role(actor, tenant, role_name) do
      {:ok,
       %__MODULE__{
         kind: :assign_role,
         summary: "Assign the #{role.name} role to #{user.email}",
         resource: Security.UserRole,
         action: :assign,
         params: %{user_id: user.id, role_id: role.id},
         details: [
           user: user.email,
           role: role.name,
           scope: "the user's own business unit"
         ]
       }}
    end
  end

  @doc """
  Can the requesting human actually perform this mutation?

  Checked before the confirmation is shown, not after it is approved: `Ash.can?`
  on the concrete action and inputs, as the person. A proposal that runs one
  action several times (a sync of each linked account) needs every one.
  """
  def authorize(%__MODULE__{} = proposal, actor, tenant) do
    if Enum.all?(inputs(proposal), &can?(proposal, &1, actor, tenant)) do
      :ok
    else
      {:error,
       "You do not have permission to #{proposal.summary |> String.downcase()}. " <>
         "This proposal was not executed."}
    end
  end

  defp can?(proposal, params, actor, tenant),
    do: Ash.can?({proposal.resource, proposal.action, params}, actor, tenant: tenant)

  @doc """
  Performs the proposed mutation, with the approving human as the actor.

  Re-checks authorization rather than trusting the earlier `authorize/2`: the
  actor's roles could have changed between the proposal being shown and
  approved, and Ash would enforce it regardless -- doing it here makes the
  failure legible instead of an opaque policy error.

  A create runs as a create, a generic action as an action; one proposal that
  runs an action per record returns the list of results.
  """
  def execute(%__MODULE__{} = proposal, actor, tenant) do
    with :ok <- authorize(proposal, actor, tenant) do
      case inputs(proposal) do
        [params] when is_map(proposal.params) ->
          run(proposal, params, actor, tenant)

        many ->
          Enum.reduce_while(many, {:ok, []}, fn params, {:ok, done} ->
            case run(proposal, params, actor, tenant) do
              {:ok, result} -> {:cont, {:ok, done ++ [result]}}
              error -> {:halt, error}
            end
          end)
      end
    end
  end

  defp inputs(%__MODULE__{params: params}) when is_list(params), do: params
  defp inputs(%__MODULE__{params: params}), do: [params]

  defp run(proposal, params, actor, tenant) do
    opts = [actor: actor, tenant: tenant, authorize?: true]

    case Ash.Resource.Info.action(proposal.resource, proposal.action).type do
      :create ->
        proposal.resource
        |> Ash.Changeset.for_create(proposal.action, params, opts)
        |> Ash.create()

      :action ->
        proposal.resource
        |> Ash.ActionInput.for_action(proposal.action, params, opts)
        |> Ash.run_action()
    end
  end

  # -- the agent chat's proposals ------------------------------------------------

  @doc """
  Proposes capturing an action item for the person: `title`, due on the local
  day `due` names (`today`, `tomorrow`, `2026-10-20`) or undated.
  """
  def create_task(_actor, _tenant, title, due) do
    title = title |> to_string() |> String.trim()

    with :ok <- present(title, "an action item needs a title"),
         {:ok, due_at} <- due_at(due) do
      {:ok,
       %__MODULE__{
         kind: :create_task,
         summary: "Add the action item \"#{clip(title, 120)}\"",
         resource: Task,
         action: :capture,
         params: %{title: clip(title, 1024), due_at: due_at, source: :assistant},
         details: [
           action_item: clip(title, 200),
           due: if(due_at, do: LocalTime.stamp(due_at), else: "no due date"),
           owner: "you"
         ]
       }}
    end
  end

  @doc """
  Proposes marking one of the person's own open tasks done. `task` is its id
  (from the task lookup) or words from its title; resolved through
  `Task.mine` as the person, and it must match exactly one open task.
  """
  def complete_task(actor, tenant, task) do
    with {:ok, %Task{} = found} <- find_own_task(actor, tenant, task) do
      {:ok,
       %__MODULE__{
         kind: :complete_task,
         summary: "Mark \"#{clip(found.title, 120)}\" done",
         resource: Task,
         action: :complete_mine,
         params: %{task_id: found.id},
         details: [
           action_item: clip(found.title, 200),
           due: found.due_at && LocalTime.stamp(found.due_at),
           status: "open → done"
         ]
       }}
    end
  end

  @doc """
  Proposes storing a reply draft to one of the person's conversations
  (`conversation` is its ref, `inbox:<id>` / `slack:<id>`, or its id). Stored
  only: nothing is sent, and there is no way to send from here.
  """
  def draft_reply(actor, tenant, conversation, body) do
    body = body |> to_string() |> String.trim()

    with :ok <- present(body, "a reply draft needs its text"),
         {:ok, id} <- record_id(conversation, "a conversation ref (inbox:… or slack:…)"),
         {:ok, %Conversation{} = found} <- find_conversation(actor, tenant, id) do
      {:ok,
       %__MODULE__{
         kind: :draft_reply,
         summary: "Save a reply draft to \"#{clip(text(found.subject), 100)}\"",
         resource: ReplyDraft,
         action: :draft,
         params: %{conversation_id: found.id, body: clip(body, 8000)},
         details: [
           conversation: clip(text(found.subject), 200),
           draft: clip(body, 2000),
           sent: "never: it is stored as a draft for you to copy"
         ]
       }}
    end
  end

  @doc """
  Proposes syncing the person's own active linked accounts now — those of
  `provider` (`gmail`, `slack`, `calendar`), or all of them for `nil`/`all`.
  """
  def sync_now(actor, tenant, provider) do
    provider = provider && provider |> to_string() |> String.trim() |> String.downcase()

    with {:ok, accounts} <- own_accounts(actor, tenant, provider) do
      keys = accounts |> Enum.map(&provider_name(&1.provider_config_key)) |> Enum.uniq()

      {:ok,
       %__MODULE__{
         kind: :sync_now,
         summary: "Sync #{Enum.join(keys, ", ")} now",
         resource: LinkedAccount,
         action: :sync_now,
         params: Enum.map(accounts, &%{record_id: &1.id}),
         details: [
           accounts: "#{length(accounts)} (#{Enum.join(keys, ", ")})",
           effect: "queues one sync step for each; a sync already queued is left as it is"
         ]
       }}
    end
  end

  @doc """
  The seam for decisions (approve or reject a brief or a task, a steward's
  confirm or reject): refused here, by design, until decisions are routed
  through the process engine's who-acts check.
  """
  @spec decision(atom(), term(), term(), term()) :: {:error, String.t()}
  def decision(kind, _actor, _tenant, _target) when kind in @decisions do
    {:error,
     "Approving, rejecting and steward verdicts are not proposed from the chat yet. " <>
       "Open the approval or the steward queue to decide."}
  end

  @doc "The decision kinds `decision/4` refuses."
  @spec decision_kinds() :: [atom()]
  def decision_kinds, do: @decisions

  @doc """
  The proposal as the page and the model see it: its kind and the resolved
  ids it would act on, string-keyed. No titles, no text but a draft's body.
  """
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{kind: :create_task, params: params}),
    do: %{
      "kind" => "create_task",
      "title" => params.title,
      "due_at" => params.due_at && DateTime.to_iso8601(params.due_at)
    }

  def to_wire(%__MODULE__{kind: :complete_task, params: params}),
    do: %{"kind" => "complete_task", "task_id" => params.task_id}

  def to_wire(%__MODULE__{kind: :draft_reply, params: params}),
    do: %{
      "kind" => "draft_reply",
      "conversation_id" => params.conversation_id,
      "body" => params.body
    }

  def to_wire(%__MODULE__{kind: :sync_now, params: params}),
    do: %{"kind" => "sync_now", "account_ids" => Enum.map(params, & &1.record_id)}

  @doc """
  Rebuilds a proposal from its wire form, resolving every id again **as
  `actor`**: a record they can no longer see, or one that has changed state,
  is an error, not a proposal.
  """
  @spec from_wire(map(), term(), term()) :: {:ok, t()} | {:error, String.t()}
  def from_wire(%{"kind" => "create_task", "title" => title} = wire, actor, tenant) do
    due =
      case wire["due_at"] && DateTime.from_iso8601(wire["due_at"]) do
        {:ok, at, _offset} -> {:at, at}
        _ -> nil
      end

    create_task(actor, tenant, title, due)
  end

  def from_wire(%{"kind" => "complete_task", "task_id" => id}, actor, tenant),
    do: complete_task(actor, tenant, id)

  def from_wire(
        %{"kind" => "draft_reply", "conversation_id" => id, "body" => body},
        actor,
        tenant
      ),
      do: draft_reply(actor, tenant, id, body)

  def from_wire(%{"kind" => "sync_now", "account_ids" => ids}, actor, tenant)
      when is_list(ids) do
    with {:ok, accounts} <- own_accounts(actor, tenant, nil) do
      chosen = Enum.filter(accounts, &(&1.id in ids))

      if length(chosen) == length(ids) and chosen != [] do
        keys = chosen |> Enum.map(&provider_name(&1.provider_config_key)) |> Enum.uniq()

        {:ok,
         %__MODULE__{
           kind: :sync_now,
           summary: "Sync #{Enum.join(keys, ", ")} now",
           resource: LinkedAccount,
           action: :sync_now,
           params: Enum.map(chosen, &%{record_id: &1.id}),
           details: [
             accounts: "#{length(chosen)} (#{Enum.join(keys, ", ")})",
             effect: "queues one sync step for each; a sync already queued is left as it is"
           ]
         }}
      else
        {:error, "Those linked accounts are no longer active, or are not yours."}
      end
    end
  end

  def from_wire(_wire, _actor, _tenant), do: {:error, "That is not a proposal this page can run."}

  # -- resolving, as the person ----------------------------------------------------

  defp present("", message), do: {:error, message}
  defp present(_value, _message), do: :ok

  defp due_at(nil), do: {:ok, nil}
  defp due_at({:at, %DateTime{} = at}), do: {:ok, at}

  defp due_at(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "" -> {:ok, nil}
      "today" -> {:ok, day_due(LocalTime.today())}
      "tomorrow" -> {:ok, day_due(Date.add(LocalTime.today(), 1))}
      text -> iso_due(text)
    end
  end

  defp iso_due(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, day_due(date)}
      {:error, _} -> {:error, "due must be today, tomorrow or a date like 2026-10-20"}
    end
  end

  # Due at 17:00 on that day in the display zone.
  defp day_due(date) do
    {from, _to} = LocalTime.days(date, 1)
    DateTime.add(from, 17, :hour)
  end

  defp find_own_task(actor, tenant, task) do
    value = task |> to_string() |> String.trim()

    query = Ash.Query.for_read(Task, :mine, %{}, actor: actor, tenant: tenant)

    query =
      case Ecto.UUID.cast(value) do
        {:ok, id} ->
          Ash.Query.filter(query, id == ^id)

        :error ->
          needle = String.downcase(value)
          Ash.Query.filter(query, status == :open and contains(string_downcase(title), ^needle))
      end

    case Ash.read(query, actor: actor, tenant: tenant, authorize?: true) do
      {:ok, [%Task{status: :open} = found]} ->
        {:ok, found}

      {:ok, [%Task{status: status}]} ->
        {:error, "That action item is already #{status}."}

      {:ok, []} ->
        {:error, "No open action item of yours matches #{inspect(clip(value, 80))}."}

      {:ok, many} ->
        {:error,
         "#{length(many)} of your open action items match; pass the id from my_tasks instead."}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  defp find_conversation(actor, tenant, id) do
    Conversation
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: actor, tenant: tenant, authorize?: true)
    |> case do
      {:ok, %Conversation{} = found} -> {:ok, found}
      {:ok, nil} -> {:error, "No conversation of yours has that ref."}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp own_accounts(actor, tenant, provider) when provider in [nil, "", "all", "any"] do
    LinkedAccount
    |> Ash.Query.for_read(:mine, %{}, actor: actor, tenant: tenant)
    |> Ash.Query.filter(lifecycle_status == :active)
    |> Ash.read(actor: actor, tenant: tenant, authorize?: true)
    |> case do
      {:ok, []} -> {:error, "You have no active linked accounts to sync."}
      {:ok, accounts} -> {:ok, accounts}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp own_accounts(actor, tenant, provider) do
    key = Map.get(@providers, provider, provider)

    with {:ok, accounts} <- own_accounts(actor, tenant, nil) do
      case Enum.filter(accounts, &(&1.provider_config_key == key)) do
        [] ->
          names = accounts |> Enum.map(&provider_name(&1.provider_config_key)) |> Enum.uniq()
          {:error, "You have no active #{provider} account. Yours: #{Enum.join(names, ", ")}."}

        matching ->
          {:ok, matching}
      end
    end
  end

  defp provider_name(key) do
    Enum.find_value(@providers, key, fn {name, config_key} -> if config_key == key, do: name end)
  end

  # A record ref (`inbox:<id>`) or a bare id.
  defp record_id(value, what) do
    id = value |> to_string() |> String.trim() |> String.split(":") |> List.last()

    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "#{inspect(clip(to_string(value), 80))} is not #{what}."}
    end
  end

  defp text(%AshEnterprise.Erasure.Shredded{}), do: "[erased]"
  defp text(nil), do: ""
  defp text(value), do: to_string(value)

  defp clip(nil, _max), do: ""

  defp clip(text, max) do
    text = to_string(text)
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  # Callers are not all models sending plain strings: `email` is an
  # `Ash.CiString` when it comes from a loaded record, and `String.trim/1` has
  # no clause for it. Normalize once, here, rather than making every caller
  # remember which shape they hold.
  defp normalize(value), do: value |> to_string() |> String.trim()

  defp find_user(actor, tenant, email) do
    Accounts.User
    |> Ash.Query.filter(email == ^normalize(email))
    |> Ash.read_one(actor: actor, tenant: tenant)
    |> case do
      {:ok, nil} -> {:error, "No user found with the email #{inspect(email)}."}
      {:ok, user} -> {:ok, user}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp find_role(actor, tenant, name) do
    Security.Role
    |> Ash.Query.filter(name == ^normalize(name))
    |> Ash.read_one(actor: actor, tenant: tenant)
    |> case do
      {:ok, nil} -> {:error, "No role found named #{inspect(name)}."}
      {:ok, role} -> {:ok, role}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end
end
