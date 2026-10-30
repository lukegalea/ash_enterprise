defmodule AshEnterprise.Test.Execution.ReferralBoard do
  @moduledoc """
  A test-only outside target for governed invocations: a clinic refers a patient to an
  outside specialist board, through the Nango façade (`AshEnterprise.Integration.Nango.Proxy`).
  In tests the board is `AshEnterprise.Test.Execution.FakeBoard`, a `Req.Test` stub, so
  nothing leaves the machine.

    * `:refer` is not idempotent: every call the board accepts is a referral. It sends
      the invocation key as the referral's `reference`, so `:find_referral` (its
      `reconcile_with`) can ask the board afterwards whether it took one.
    * `:refer_keyed` sends the invocation key as the board's `Idempotency-Key` too, and
      is declared idempotent: the board takes one referral per key however often it is
      called.
    * `:refer_unchecked` is `:refer` with no lookup: a lost acknowledgement waits for a
      person.
    * `:refer_later_keyed` hands the referral over and returns a dispatch
      (`AshAgent.Invocation.Dispatch`) due in a day: the board answers later. It is
      idempotent, so a passed deadline fails it as a timeout rather than leaving it
      unknown.

  After the board accepts, each passes the fault point `:referral_accepted`, where a
  test can kill the worker between the outside effect and its record.

  Self-service (ADR 0052), so a member with no role may run them as themselves. Generic
  actions only, no table.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Test.Execution,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    self_service: [:refer, :refer_keyed, :refer_unchecked, :refer_later_keyed, :find_referral],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Integration.Nango.Proxy
  alias AshEnterprise.Integration.ProxyError

  resource do
    require_primary_key? false
  end

  effects do
    action :refer,
      kind: :execute,
      destructive?: false,
      intent: :execute,
      reconcile_with: :find_referral

    action :refer_keyed,
      kind: :execute,
      destructive?: false,
      idempotent?: true,
      intent: :execute

    action :refer_unchecked, kind: :execute, destructive?: false, intent: :execute

    action :refer_later_keyed,
      kind: :execute,
      destructive?: false,
      idempotent?: true,
      intent: :execute

    action :find_referral,
      kind: :fetch,
      destructive?: false,
      idempotent?: true,
      intent: :inspect
  end

  actions do
    action :refer, :map do
      argument :patient, :string, allow_nil?: false
      run fn input, _context -> refer(input, false) end
    end

    action :refer_keyed, :map do
      argument :patient, :string, allow_nil?: false
      run fn input, _context -> refer(input, true) end
    end

    action :refer_unchecked, :map do
      argument :patient, :string, allow_nil?: false
      run fn input, _context -> refer(input, false) end
    end

    action :refer_later_keyed, :struct do
      constraints instance_of: AshAgent.Invocation.Dispatch
      argument :patient, :string, allow_nil?: false

      run fn input, _context ->
        with {:ok, %{"id" => id}} <- refer(input, true) do
          {:ok,
           AshAgent.Invocation.Dispatch.new(
             effect_system: "referral-board",
             effect_ref: id,
             deadline_at: DateTime.add(DateTime.utc_now(), 1, :day)
           )}
        end
      end
    end

    action :find_referral, :map do
      argument :invocation_key, :string, allow_nil?: false

      run fn input, _context ->
        %{
          method: :get,
          path: "/referrals",
          query: [{"reference", input.arguments.invocation_key}],
          provider_config_key: "referral-board",
          connection_id: "clinic"
        }
        |> Proxy.request(operation: :find_referral)
        |> case do
          {:ok, %{body: %{"id" => id}}} ->
            {:ok,
             %{"outcome" => "succeeded", "effect_ref" => id, "effect_system" => "referral-board"}}

          {:error, %ProxyError{reason: :not_found}} ->
            {:ok, %{"outcome" => "not_found"}}

          {:error, error} ->
            {:error, error}
        end
      end
    end
  end

  defp refer(input, keyed?) do
    key = input.context.ash_agent.invocation_key

    request = %{
      method: :post,
      path: "/referrals",
      body: %{"patient" => input.arguments.patient, "reference" => key},
      provider_config_key: "referral-board",
      connection_id: "clinic"
    }

    request = if keyed?, do: Map.put(request, :idempotency_key, key), else: request

    with {:ok, %{body: body}} <- Proxy.request(request, operation: :refer) do
      AshEnterprise.Faults.point(:referral_accepted)
      {:ok, body}
    end
  end
end
