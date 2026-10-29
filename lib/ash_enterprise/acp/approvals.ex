defmodule AshEnterprise.Acp.Approvals do
  @moduledoc """
  `AshAcp.PermissionRequest` seam (ADR 0015). Pending approvals live in the
  same supervised ETS store as sessions until epic E5's durable approval
  resource replaces them.

  Binding rule: a resolution is only recorded when the ref exists **and**
  belongs to the session that is resolving it — an unknown or foreign ref can
  never approve anything.
  """

  @behaviour AshAcp.PermissionRequest

  alias AshEnterprise.Acp

  @impl true
  # An extension method asks only for what is consequential — a write through
  # a surface (`AshEnterprise.Acp.ExtMethods`) — so it always pends: the
  # person decides, and the action then still runs under their policies.
  def request(session, %{ext: _} = action_spec, inputs), do: pend(session, action_spec, inputs)

  def request(session, action_spec, inputs) do
    Acp.ensure_tables!()

    actor = session.actor
    tenant = Acp.tenant_of(actor)

    # ADR 0015 seam: approvals gate *privileged* operations. An action policy
    # already authorizes runs without a modal — else every authorized read
    # nags. Only actions policy does not authorize become pending approvals.
    authorized? = Ash.can?({action_spec.resource, action_spec.action}, actor, tenant: tenant)

    # The action's effects declaration decides (ADR 0057): reads and the
    # generic actions behind the daily-loop prompts declared `approval: :none`
    # (digests, help, one's own action items) run without a modal when
    # authorized. Everything else always pends — dogfood §5's
    # capability-transition rule: consequential operations are approvals, even
    # for the operator.
    if authorized? and not Acp.asks_first?(action_spec.resource, action_spec.action) do
      {:approved, %{auto: :policy_authorized, tenant: tenant}}
    else
      pend(session, action_spec, inputs)
    end
  end

  defp pend(session, action_spec, inputs) do
    Acp.ensure_tables!()
    ref = Ash.UUID.generate()

    :ets.insert(
      Acp.approvals_table(),
      {ref,
       %{
         session_id: session.session_id,
         action_spec: action_spec,
         inputs: inputs,
         status: :pending
       }}
    )

    {:pending, ref}
  end

  @impl true
  def resolve(ref, outcome, session) when is_binary(ref) do
    status =
      case outcome do
        # Wire shape: %{"outcome" => "selected", "optionId" => "allow_once"|"allow_always"}
        %{"outcome" => "selected", "optionId" => option}
        when option in ["allow_once", "allow_always"] ->
          :approved

        _ ->
          :denied
      end

    case :ets.lookup(Acp.approvals_table(), ref) do
      [{key, %{session_id: sid, status: :pending} = record}] when sid == session.session_id ->
        :ets.insert(Acp.approvals_table(), {key, Map.put(record, :status, status)})

        if status == :approved do
          {:approved, %{ref: ref}}
        else
          {:denied}
        end

      # Unknown ref, already-resolved ref, or a ref belonging to another
      # session: never approve anything.
      _ ->
        {:denied}
    end
  end

  # A ref this module did not issue never approves anything.
  def resolve(_ref, _outcome, _session), do: {:denied}
end
