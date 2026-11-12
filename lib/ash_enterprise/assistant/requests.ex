defmodule AshEnterprise.Assistant.Requests do
  @moduledoc """
  What the assistant asked to do (ADR 0055): a call a run of the assistant makes to one
  of its effects-declared targets (`AshEnterprise.Assistant.Agent`) is not run in the
  loop. It is an `AshEnterprise.Execution.Invocation`, keyed
  `run:<run id>:<step seq>:<tool call id>`, requested as the person who asked the
  question. Every such target declares `approval: :confirm`, so the row waits in
  `awaiting_approval` on its approval task, whose only candidate is that person.

  The answer ends there (`AshEnterprise.Assistant.Ask`): the page shows each request
  with Confirm and Cancel, and later what became of it. This module is what the page
  needs of those rows, for their owner only:

    * `of_run/3`: a run's requests, by the tool call that made them;
    * `get/3`: one request;
    * `confirm/3` and `decline/3`: the person's own decision, through
      `AshEnterprise.Execution.Actions.ConfirmInvocation`. Confirming approves the task
      as the person as they are now, applies the decision and runs the target once,
      as them, inline. Declining rejects the task, and nothing runs;
    * `describe/3`: what the request would do, read as the person: data for the page
      to put into words, never the words themselves.

  The rows are read without authorization and filtered to the person's own
  (`owner_id`), as `AshEnterprise.Acp.Approvals` reads a session's: a person may hold no
  grant on invocations at all, and these are theirs. A request of anyone else's is not
  found.
  """

  require Ash.Query

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Canonical.{Conversation, Task}
  alias AshEnterprise.Execution.Actions.ConfirmInvocation
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Mdm.MatchCandidate

  @final [:succeeded, :failed, :rejected, :stale, :cancelled]

  @typedoc "What a request would do, for the page to put into words."
  @type description :: %{required(:kind) => atom(), optional(atom()) => String.t() | nil}

  @doc "The statuses a request ends in."
  @spec final() :: [atom()]
  def final, do: @final

  @doc """
  The requests the run `run_id` made, as `%{tool_call_id => invocation}`: the person's
  own only.
  """
  @spec of_run(Ash.UUID.t(), Ash.Resource.record(), Ash.UUID.t() | nil) :: %{
          String.t() => Ash.Resource.record()
        }
  def of_run(run_id, %{id: owner_id}, tenant) when is_binary(tenant) do
    Invocation
    |> Ash.Query.filter(run_id == ^run_id and owner_id == ^owner_id)
    |> Ash.read(authorize?: false, tenant: tenant)
    |> case do
      {:ok, rows} -> Map.new(rows, &{&1.tool_call_id, &1})
      {:error, _error} -> %{}
    end
  end

  def of_run(_run_id, _actor, _tenant), do: %{}

  @doc "The person's own request `id`, or `:error`."
  @spec get(Ash.UUID.t(), Ash.Resource.record(), Ash.UUID.t() | nil) ::
          {:ok, Ash.Resource.record()} | :error
  def get(id, %{id: owner_id}, tenant) when is_binary(id) and is_binary(tenant) do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         {:ok, %{owner_id: ^owner_id} = row} <-
           Ash.get(Invocation, id, authorize?: false, tenant: tenant) do
      {:ok, row}
    else
      _missing_or_not_theirs -> :error
    end
  end

  def get(_id, _actor, _tenant), do: :error

  @doc """
  The person confirms their request `id`: it runs now, as them. Returns the request as
  it then stands; one already decided is returned as it is, and nothing runs twice.
  """
  @spec confirm(Ash.UUID.t(), Ash.Resource.record(), Ash.UUID.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def confirm(id, actor, tenant) do
    with {:ok, row} <- found(id, actor, tenant) do
      ConfirmInvocation.confirm(row, actor, tenant)
    end
  end

  @doc "The person declines their request `id`: it is rejected, and nothing runs."
  @spec decline(Ash.UUID.t(), Ash.Resource.record(), Ash.UUID.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def decline(id, actor, tenant) do
    with {:ok, row} <- found(id, actor, tenant) do
      ConfirmInvocation.decline(row, actor, tenant)
    end
  end

  defp found(id, actor, tenant) do
    case get(id, actor, tenant) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  What `row` would do, read as `actor`: its kind and the few names a person needs to
  recognise it (the action item's title, the conversation's subject, the task's name,
  both sides of a duplicate). A record they can no longer read, or arguments erased
  with their scope, leave the names out; the kind is always there.
  """
  @spec describe(Ash.Resource.record(), Ash.Resource.record(), Ash.UUID.t()) :: description()
  def describe(row, actor, tenant) do
    args = args(row)
    opts = [actor: actor, tenant: tenant, authorize?: true]

    case row.target |> String.split(".") |> Enum.take(-2) do
      ["Task", "capture"] ->
        %{kind: :add_action_item, title: text(args["title"]), due: text(args["due_at"])}

      ["Task", "complete_mine"] ->
        %{kind: :finish_action_item, title: task_label(args["record_id"], opts)}

      ["ReplyDraft", "draft"] ->
        %{
          kind: :draft_reply,
          subject: conversation_subject(args["conversation_id"], opts),
          body: text(args["body"])
        }

      ["LinkedAccount", "sync_now"] ->
        %{kind: :sync_account, account: account_provider(args["record_id"], opts)}

      ["HumanTask", decision] when decision in ["approve", "reject"] ->
        Map.merge(
          %{kind: String.to_existing_atom(decision <> "_task"), comment: text(args["comment"])},
          human_task(args["record_id"], opts)
        )

      ["MatchCandidate", verdict] when verdict in ["confirm", "reject", "escalate"] ->
        Map.put(duplicate(args["id"], opts), :kind, verdict_kind(verdict))

      _other ->
        %{
          kind: :other,
          target: row.target |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
        }
    end
  end

  @doc """
  The field errors of a request the pre-check refused at request time (`error_code`
  `invalid_request`): one message per input at fault. The details are sealed with the
  row, like its arguments: loaded for its owner, and none once erased. A refusal of
  permission carries only "not permitted", and a row that was not refused, nothing.
  """
  @spec rejection_messages(Ash.Resource.record()) :: [String.t()] | nil
  def rejection_messages(%{status: :rejected} = row) do
    case Ash.load(row, [:rejection_details], authorize?: false, tenant: row.organization_id) do
      {:ok, %{rejection_details: %{"errors" => errors}}} when is_list(errors) ->
        errors |> Enum.map(& &1["message"]) |> Enum.reject(&is_nil/1)

      _none_or_erased ->
        nil
    end
  end

  def rejection_messages(_row), do: nil

  defp verdict_kind("confirm"), do: :merge_duplicate
  defp verdict_kind("reject"), do: :keep_duplicate_separate
  defp verdict_kind("escalate"), do: :mark_duplicate_unsure

  # The arguments are sealed with the row: loaded for its owner, and empty once erased.
  defp args(row) do
    case Ash.load(row, [:args], authorize?: false, tenant: row.organization_id) do
      {:ok, %{args: args}} when is_map(args) -> args
      _erased -> %{}
    end
  end

  defp task_label(id, opts) do
    with {:ok, task} <- read(Task, id, opts),
         {:ok, task} <- Ash.load(task, [:label], opts) do
      text(task.label)
    else
      _ -> nil
    end
  end

  defp conversation_subject(id, opts) do
    case read(Conversation, id, opts) do
      {:ok, conversation} -> text(conversation.subject)
      _ -> nil
    end
  end

  defp account_provider(id, opts) do
    case read(LinkedAccount, id, opts) do
      {:ok, account} ->
        AshEnterprise.Integration.Calculations.AccountHealth.provider(account.provider_config_key)

      _ ->
        nil
    end
  end

  defp human_task(id, opts) do
    with {:ok, task} <- read(HumanTask, id, opts),
         {:ok, task} <- Ash.load(task, [:subject_label], opts) do
      %{task: text(task.name), about: text(task.subject_label)}
    else
      _ -> %{}
    end
  end

  defp duplicate(id, opts) do
    with {:ok, candidate} <- read(MatchCandidate, id, opts),
         {:ok, candidate} <- Ash.load(candidate, [:staged_label, :golden_label], opts) do
      %{incoming: text(candidate.staged_label), existing: text(candidate.golden_label)}
    else
      _ -> %{}
    end
  end

  defp read(resource, id, opts) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Ash.get(resource, id, opts)
      :error -> :error
    end
  end

  defp read(_resource, _id, _opts), do: :error

  defp text(nil), do: nil
  defp text(%AshEnterprise.Erasure.Shredded{}), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(value), do: to_string(value)
end
