defmodule AshEnterprise.Acp.Approvals do
  @moduledoc """
  `AshAcp.PermissionRequest` seam (ADR 0015, ADR 0055): what ACP asks the person
  before it runs something, and where their answer is kept.

  ## A prompt's request is an invocation

  A prompt routes to a declared Ash action (`AshEnterprise.Acp.Commands`). When its
  effects declaration asks for an approval (`AshEnterprise.Acp.asks_first?/2`), the
  route does not run the action: it runs `Invocation.confirm` for it, with a key
  (`key/4`). Asked about that, `request/3` makes the request an
  `AshEnterprise.Execution.Invocation` through `invoke`, as the person: under
  `:confirm` it waits in `awaiting_approval` on its standalone approval task, which the
  person is the candidate for. Its id is the permission request's ref.

  So the request is durable. It survives the session store, the connection and a
  restart; it is on the person's approvals list on the web too; and a client that
  sends the same request again, in this session or a new one, finds the same row:
  `key/4` returns the key of the person's own request for the same target and
  arguments while it still waits, so `invoke` returns that row instead of making a
  second.

  The person's answer:

    * `allow_once` approves nothing by itself: `resolve/3` checks the ref and answers
      approved, and ash_acp then runs `Invocation.confirm`, which approves the task as
      the person, applies the decision and runs the target once
      (`AshEnterprise.Execution.Actions.ConfirmRequest`);
    * `reject_once` rejects the task, and the decision is applied: the row is
      `rejected` and nothing runs;
    * a cancelled request, or an option that was not offered, decides nothing: the row
      keeps waiting, for this client or the web.

  `allow_always` is not offered (`config :ash_acp, permission_options:`): there is no
  standing grant for it to record.

  Binding rule: a ref approves only when it names an invocation the session's person
  owns that still waits for approval, so an unknown or foreign ref, or one already
  decided, approves nothing.

  ## A surface action is a confirmation

  An extension call (`_a2ui/action`, `AshEnterprise.Acp.ExtMethods`) is a click on a
  surface: it names its action exactly, and the web runs the same click with no
  approval record. An A2UI action may also delegate to code other than the action it
  names (`via`), so its declaration does not say what runs. ACP asks the person to
  confirm it, and their answer decides only whether the click runs, as them, under
  their policies. Nothing is recorded: the ref names the session, so another session
  cannot answer it.

  Anything else runs at once when its declaration does not ask; a declared approval
  routed around an invocation, or an undeclared write, is refused, because nothing
  could approve it.
  """

  @behaviour AshAcp.PermissionRequest

  require Ash.Query

  alias AshEnterprise.Acp
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Actions.ConfirmInvocation
  alias AshEnterprise.Execution.Invocation

  # How many of a person's waiting requests for one target `key/4` compares.
  @waiting_scan 20

  @impl true
  def request(session, %{click: _surface} = _action_spec, _inputs),
    do: {:pending, {:confirmation, session.session_id}}

  def request(session, %{resource: Invocation, action: :confirm}, inputs) do
    actor = session.actor
    tenant = Acp.tenant_of(actor)

    case Execution.invoke(inputs.target, inputs.args, %{key: inputs.key},
           actor: actor,
           tenant: tenant
         ) do
      {:ok, %{status: :awaiting_approval} = row} -> {:pending, row.id}
      {:ok, %{status: :rejected}} -> {:denied}
      {:ok, row} -> {:approved, %{"invocation_id" => row.id, "status" => to_string(row.status)}}
      {:error, _refused} -> {:denied}
    end
  end

  def request(session, action_spec, _inputs) do
    if Acp.asks_first?(action_spec.resource, action_spec.action),
      do: {:denied},
      else: {:approved, %{auto: :no_approval, tenant: Acp.tenant_of(session.actor)}}
  end

  @impl true
  def resolve({:confirmation, session_id}, outcome, %{session_id: session_id}) do
    if allowed?(outcome), do: {:approved, nil}, else: {:denied}
  end

  def resolve(ref, outcome, session) when is_binary(ref) do
    actor = session.actor
    tenant = Acp.tenant_of(actor)

    with true <- is_binary(tenant) and match?({:ok, _}, Ecto.UUID.cast(ref)),
         {:ok, %{status: :awaiting_approval, owner_id: owner} = row} when owner == actor.id <-
           Execution.get_invocation(ref, authorize?: false, tenant: tenant) do
      cond do
        allowed?(outcome) ->
          {:approved, %{"invocation_id" => row.id}}

        rejected?(outcome) ->
          _ = ConfirmInvocation.decline(row, actor, tenant)
          {:denied}

        true ->
          {:denied}
      end
    else
      _unknown_foreign_or_decided -> {:denied}
    end
  end

  # A ref this module did not issue never approves anything.
  def resolve(_ref, _outcome, _session), do: {:denied}

  defp allowed?(%{"outcome" => "selected", "optionId" => "allow_once"}), do: true
  defp allowed?(_outcome), do: false

  defp rejected?(%{"outcome" => "selected", "optionId" => "reject_once"}), do: true
  defp rejected?(_outcome), do: false

  @doc """
  The key a prompt's request of `target` with `args` is invoked under, for `actor` in
  `tenant`: the key of their own request for the same target and arguments that still
  waits for approval, if there is one, so asking again finds it; otherwise a new one.

  "The same arguments" is `invoke`'s own test: the same key with the same target,
  arguments, principal and parent returns the row, and anything else is a conflict.
  Asking that changes nothing. The waiting rows are read without authorization (the
  person may hold no grant on invocations), and only their own.
  """
  @spec key(Ash.Resource.record(), String.t(), map(), Ash.UUID.t() | nil) :: String.t()
  def key(actor, target, args, tenant) do
    Invocation
    |> Ash.Query.filter(
      owner_id == ^actor.id and target == ^target and status == :awaiting_approval and
        is_nil(run_id)
    )
    |> Ash.Query.sort(created_on: :desc)
    |> Ash.Query.limit(@waiting_scan)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.find_value(fn row ->
      case Execution.invoke(target, args, %{key: row.invocation_key},
             actor: actor,
             tenant: tenant
           ) do
        {:ok, %{id: id}} when id == row.id -> row.invocation_key
        _different_request -> nil
      end
    end) || "acp:" <> Ash.UUIDv7.generate()
  end
end
