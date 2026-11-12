defmodule AshEnterprise.Channels do
  @moduledoc """
  One vocabulary for what an act came to, whichever channel it came through (R2 HW-07,
  AGT-54): the web's A2UI surfaces (`/ui/feedback`) and ACP (`_a2ui/action`, the prompt
  grammar) answer with the same result, and an act that cannot go ahead says why with
  the same blocked reason.

  ## Results

  | Result | What happened |
  |---|---|
  | `applied` | the act ran and its effect is done |
  | `pending` | the act was accepted as a request that waits on someone: an approval, an answer |
  | `declined` | the person asked to confirm said no |
  | `forbidden` | policy refused it |
  | `invalid` | its input was refused |
  | `failed` | anything else: an error, or an outcome this module does not recognise |

  `failed` is the floor: nothing unrecognised reads as `applied` or `pending`.

  ## Blocked reasons

  | Reason | Why the act does not go ahead |
  |---|---|
  | `forbidden` | the actor may not do it, or the principal it runs as may not |
  | `approval_required` | it waits for an approval, or for the requester's answer to an approver, or its approval no longer binds and it must be asked for again |
  | `policy_failed` | a decision refused it: an approver rejected it, or a business rule did |
  | `integration_unavailable` | the system it reaches is not answering, or its outcome there is not known yet |

  `blocked_reason/1` answers one of these, `:none` for an act that is going ahead or
  done, and `:unclassified` for anything else. An unrecognised status is never `:none`.

  ## Where each channel reads them

    * Web: `AshEnterpriseWeb.A2ui.Host.act/3`, the action function of every surface
      page, adds `"result"` (and, when there is one, `"blockedReason"`) to the
      `/ui/feedback` value the action handler wrote.
    * ACP: `AshEnterprise.Acp.ExtMethods` answers `_a2ui/action` with `"result"`
      beside its `outcome` (`applied`, `denied`, `failed`), and `"blockedReason"`.

  Both compute them here (`outcome/2`), from the same handler outcome, so the two cannot
  drift.
  """

  alias AshEnterprise.Execution.Actions.{
    ConfirmInvocation,
    RequestInvocation,
    RequestPublish,
    RequestRelease
  }

  @results [:applied, :pending, :declined, :forbidden, :invalid, :failed]
  @blocked_reasons [:forbidden, :approval_required, :policy_failed, :integration_unavailable]

  @doc "The results an act answers with, on every channel."
  @spec results() :: [atom()]
  def results, do: @results

  @doc "The reasons an act is blocked, on every channel."
  @spec blocked_reasons() :: [atom()]
  def blocked_reasons, do: @blocked_reasons

  # --- the act an A2UI action runs ---------------------------------------------------

  @doc """
  The resource and the Ash action an A2UI action runs, as `AshA2ui.ActionHandler`
  resolves it: a form by its create or update action, a row or bulk action by its name in
  the view's allowlist, a cell by its table's update action. `{resource, nil}` for an
  action that runs no Ash action (a query, a search, a prompt, a report, an export).
  """
  @spec target(module(), String.t() | nil, map() | nil) :: {Ash.Resource.t(), atom() | nil}
  def target(ui, name, context) do
    view = AshA2ui.ResolvedView.resolve(ui, [])
    {view.resource, ash_action(view, name, context || %{})}
  end

  @doc "`target/3` for an A2UI action envelope, bare or wrapped in `\"action\"`."
  @spec envelope_target(module(), map()) :: {Ash.Resource.t(), atom() | nil}
  def envelope_target(ui, %{"action" => %{"name" => name} = inner}),
    do: target(ui, name, inner["context"])

  def envelope_target(ui, %{"name" => name} = envelope), do: target(ui, name, envelope["context"])
  def envelope_target(ui, _envelope), do: target(ui, nil, %{})

  defp ash_action(view, "submit_form", context),
    do: if(context["recordId"], do: view.update_action, else: view.create_action)

  defp ash_action(view, "invoke", context), do: named(view.row_actions, context["action"])
  defp ash_action(view, "bulk_invoke", context), do: named(view.bulk_actions, context["action"])

  defp ash_action(%{tables: tables}, "edit_cell", context) do
    table =
      case tables do
        [table] -> table
        tables -> Enum.find(tables, &(to_string(&1.name) == context["component"]))
      end

    case table do
      %{editable: %{update_action: action}} -> action
      _none -> nil
    end
  end

  defp ash_action(_view, _name, _context), do: nil

  defp named(actions, name) when is_binary(name),
    do: Enum.find(List.wrap(actions), &(Atom.to_string(&1) == name))

  defp named(_actions, _name), do: nil

  # --- results -----------------------------------------------------------------------

  @doc """
  What an action handler's outcome (`{:ok | :error, messages}`) came to, for the Ash
  action it ran (`target/3`): `{result, blocked_reason}`, the pair both channels write.

  A request door (an action that asks for a governed invocation) answers with the
  invocation its request became, and that row's status is the answer: `applied` once it
  succeeded (a door that confirms and runs at once, or a keyed door handing back a row
  that already ran), `pending` while it waits or runs, `failed` once it was refused or
  failed, with the row's blocked reason (`policy_failed` for a rejection,
  `integration_unavailable` for an unknown outcome or an unreachable system). A request
  refused as it was asked is `forbidden` when its principal may not make it
  (`not_permitted`), and `invalid` when the action refuses its input
  (`invalid_request`, blocked as `policy_failed`). A door
  answer with no status this module knows is `failed`, never `pending`.
  """
  @spec outcome({:ok | :error, [map()]} | term(), {module(), atom() | nil}) ::
          {atom(), atom()}
  def outcome({:ok, messages} = handled, {resource, action} = target)
      when is_list(messages) and not is_nil(action) do
    if request_door?(resource, action) do
      case door_row(messages) do
        %{status: status} = row when not is_nil(status) ->
          {door_result(row), blocked_reason(row)}

        _unknown ->
          {:failed, :unclassified}
      end
    else
      plain(handled, target)
    end
  end

  def outcome(handled, target), do: plain(handled, target)

  defp plain(handled, target) do
    result = result(handled, target)
    {result, blocked_reason(result)}
  end

  @doc """
  The result alone of an action handler's outcome for the Ash action it ran: see
  `outcome/2`.
  """
  @spec result({:ok | :error, [map()]} | term(), {module(), atom() | nil}) :: atom()
  def result({:ok, messages} = handled, {resource, action} = target)
      when is_list(messages) and not is_nil(action) do
    if request_door?(resource, action),
      do: handled |> outcome(target) |> elem(0),
      else: :applied
  end

  def result({:ok, messages}, {_resource, nil}) when is_list(messages), do: :applied

  def result({:error, messages}, _target) when is_list(messages) do
    case failure_kind(messages) do
      :invalid -> :invalid
      :forbidden -> :forbidden
      :error -> :failed
    end
  end

  def result(_unknown, _target), do: :failed

  @doc "The result of an ACP answer whose person declined to confirm it."
  @spec declined() :: :declined
  def declined, do: :declined

  @doc """
  The result an ACP `outcome` (and the error `kind` of a failed one) stands for.
  Anything else is `failed`.
  """
  @spec from_acp(map()) :: atom()
  def from_acp(%{"result" => result}) when is_binary(result), do: known(result)
  def from_acp(%{"outcome" => "applied"}), do: :applied
  def from_acp(%{"outcome" => "denied"}), do: :declined
  def from_acp(%{"outcome" => "failed", "error" => %{"kind" => "forbidden"}}), do: :forbidden
  def from_acp(%{"outcome" => "failed", "error" => %{"kind" => "invalid"}}), do: :invalid
  def from_acp(_other), do: :failed

  @doc "The result a web `/ui/feedback` value carries. Anything else is `failed`."
  @spec from_feedback(map() | term()) :: atom()
  def from_feedback(%{"result" => result}) when is_binary(result), do: known(result)
  def from_feedback(_other), do: :failed

  defp known(result) do
    Enum.find(@results, :failed, &(Atom.to_string(&1) == result))
  end

  @doc """
  Whether `action` on `resource` is a request door: a generic action that asks for a
  governed invocation (`RequestInvocation` and the doors built on it) rather than doing
  the act itself.
  """
  @spec request_door?(module(), atom()) :: boolean()
  def request_door?(resource, action), do: not is_nil(door_target(resource, action))

  @doc """
  The governed action a request door asks for (`request_activation` asks for
  `activate_credential`), or nil when `action` is no request door.
  """
  @spec door_target(module(), atom()) :: atom() | nil
  def door_target(resource, action) do
    case Ash.Resource.Info.action(resource, action) do
      %{type: :action, run: {RequestInvocation, opts}} -> opts[:target]
      %{type: :action, run: {RequestRelease, _opts}} -> :promote
      %{type: :action, run: {RequestPublish, _opts}} -> :apply_publish
      %{type: :action, run: {ConfirmInvocation, opts}} -> opts[:target]
      _other -> nil
    end
  end

  @pending_statuses [
    :requested,
    :awaiting_approval,
    :request_info,
    :ready,
    :executing,
    :dispatched,
    :outcome_unknown
  ]

  # Refused as it was asked (the request-time pre-check): by policy, or for its input.
  defp door_result(%{status: :rejected, error_code: "not_permitted"}), do: :forbidden
  defp door_result(%{status: :rejected, error_code: "invalid_request"}), do: :invalid
  defp door_result(%{status: status}), do: door_result(status)
  defp door_result(:succeeded), do: :applied
  defp door_result(status) when status in @pending_statuses, do: :pending
  defp door_result(_refused_failed_stale_cancelled_or_unknown), do: :failed

  # The row a door answered with, as `AshA2ui.ActionHandler` wrote the generic action's
  # result: `/ui/action_result` on an A2UI 0.9.1 surface, the `/ui/response` result on a
  # 1.0 one. Its status and failure class are read against the invocation's own
  # vocabularies; anything else is nil.
  defp door_row(messages) do
    answer =
      Enum.find_value(messages, fn
        %{"updateDataModel" => %{"path" => "/ui/action_result", "value" => %{} = value}}
        when map_size(value) > 0 ->
          value

        %{"updateDataModel" => %{"path" => "/ui/response", "value" => %{"result" => %{} = value}}}
        when map_size(value) > 0 ->
          value

        _other ->
          nil
      end)

    case answer do
      %{"status" => status} = answer ->
        %{
          status: known_atom(status, invocation_statuses()),
          failure_class:
            known_atom(answer["failure_class"], AshAgent.Invocation.failure_classes()),
          error_code: answer["error_code"]
        }

      _no_row ->
        nil
    end
  end

  defp invocation_statuses,
    do:
      Ash.Resource.Info.attribute(AshEnterprise.Execution.Invocation, :status).constraints[
        :one_of
      ]

  defp known_atom(value, known) when is_binary(value),
    do: Enum.find(known, &(Atom.to_string(&1) == value))

  defp known_atom(_value, _known), do: nil

  # `AshA2ui.ActionHandler` answers a failure with data-model messages only, so the kind
  # is read back from them. A field error is under `/errors/<field>`. A policy refusal
  # carries nothing else, so policy details do not leak: on an A2UI 1.0 surface
  # `/ui/response` with code `UNAUTHORIZED`, on a 0.9.1 one the typed `/ui/feedback`
  # error carrying exactly the handler's fixed refusal sentence.
  @forbidden_status "You are not authorized to perform this action."

  @doc false
  @spec failure_kind([map()]) :: :forbidden | :invalid | :error
  def failure_kind(messages) do
    updates =
      for %{"updateDataModel" => %{"path" => path} = update} <- messages,
          do: {path, update["value"]}

    cond do
      Enum.any?(updates, &invalid?/1) -> :invalid
      Enum.any?(updates, &forbidden?/1) -> :forbidden
      true -> :error
    end
  end

  defp invalid?({"/errors/" <> _field, _value}), do: true
  defp invalid?({"/ui/response", %{"code" => "VALIDATION_FAILED"}}), do: true
  defp invalid?(_update), do: false

  defp forbidden?({"/ui/response", %{"code" => "UNAUTHORIZED"}}), do: true

  defp forbidden?({"/ui/feedback", %{"kind" => "error", "message" => @forbidden_status}}),
    do: true

  defp forbidden?(_update), do: false

  # --- blocked reasons -----------------------------------------------------------------

  @going [:requested, :ready, :executing, :dispatched, :succeeded, :cancelled]
  @waiting [:awaiting_approval, :request_info, :stale]
  @unreachable [:transient, :timeout]

  @doc """
  Why an act is blocked: from a result (`:forbidden`, `:pending`), an Ash error, or the
  invocation it became. `:none` when it is going ahead or done, `:unclassified` when it
  failed for a reason outside the vocabulary or is not recognised at all.
  """
  @spec blocked_reason(term()) :: atom()
  def blocked_reason(:forbidden), do: :forbidden
  def blocked_reason(:pending), do: :approval_required
  def blocked_reason(:applied), do: :none
  def blocked_reason(%Ash.Error.Forbidden{}), do: :forbidden

  def blocked_reason(%{status: :failed, failure_class: :denied}), do: :forbidden
  def blocked_reason(%{status: :failed, error_code: "no_authority" <> _}), do: :forbidden
  def blocked_reason(%{status: :rejected, error_code: "not_permitted"}), do: :forbidden
  def blocked_reason(%{status: :rejected}), do: :policy_failed
  def blocked_reason(%{status: :failed, failure_class: :business}), do: :policy_failed
  def blocked_reason(%{status: :outcome_unknown}), do: :integration_unavailable

  def blocked_reason(%{status: :failed, failure_class: class}) when class in @unreachable,
    do: :integration_unavailable

  # A transient failure waiting to be tried again: ready, with an attempt behind it.
  def blocked_reason(%{status: :ready, failure_class: class}) when class in @unreachable,
    do: :integration_unavailable

  def blocked_reason(%{status: status}) when status in @waiting, do: :approval_required
  def blocked_reason(%{status: status}) when status in @going, do: :none
  def blocked_reason(_other), do: :unclassified

  # --- the wire ------------------------------------------------------------------------

  @doc """
  The handler's messages with `result` (and `blocked`, unless it is `:none` or
  `:unclassified`) added to the `/ui/feedback` value they write. Messages that write no
  feedback are left as they are: a query or a search answers nothing about an act.

  A request door answers with its row even when the request failed, was rejected or went
  stale, and the handler, which ran the door without error, writes a success. When the
  result is `failed`, that success becomes an error naming what the request came to, so
  the person reads the same answer the result carries.
  """
  @spec annotate_feedback([map()], atom(), atom()) :: [map()]
  def annotate_feedback(messages, result, blocked) do
    Enum.map(messages, fn
      %{"updateDataModel" => %{"path" => "/ui/feedback", "value" => value} = update} = message
      when is_map(value) ->
        value = value |> refused(result, messages) |> wire(result, blocked)
        %{message | "updateDataModel" => %{update | "value" => value}}

      message ->
        message
    end)
  end

  defp refused(%{"kind" => "success"} = value, :failed, messages) do
    case door_row(messages) do
      %{status: status, error_code: code} when not is_nil(status) ->
        %{
          value
          | "kind" => "error",
            "message" =>
              "The request #{status}#{if code, do: ": " <> code, else: ""}. Nothing was changed."
        }

      _no_row ->
        value
    end
  end

  defp refused(value, _result, _messages), do: value

  @doc "`answer` (an ACP `_a2ui/action` answer) with `result` and `blocked` added."
  @spec annotate_answer(map(), atom(), atom()) :: map()
  def annotate_answer(answer, result, blocked), do: wire(answer, result, blocked)

  defp wire(map, result, blocked) when blocked in @blocked_reasons,
    do:
      map
      |> Map.put("result", Atom.to_string(result))
      |> Map.put("blockedReason", Atom.to_string(blocked))

  defp wire(map, result, _none_or_unclassified),
    do: Map.put(map, "result", Atom.to_string(result))
end
