defmodule AshEnterprise.Test.Execution.NoNetwork do
  @moduledoc """
  The no-network contract for internal targets (ADR 0055, plan risk 5).

  A target declared `open_world?: false` runs on the internal path: its effect and the
  invocation's completion commit in one transaction, which is what makes "exactly one
  committed effect" true. That holds only if nothing the action does reaches outside
  the transaction. A change can add a `before_transaction`, `after_transaction` or
  `around_transaction` hook at runtime, and a hook that calls out has told the world
  about an effect that may roll back.

  `check/3` holds one target to that:

    1. it builds the action with generated inputs (`Ash.Generator.action_input/2`) as
       the given actor, and reports any transaction hook the action's changes attached;
    2. it runs it inside a transaction that is always rolled back, with every outbound
       HTTP request through `Req` blocked and recorded (`Req.Test`: the Nango façade's
       own stub, and a `Req` default for any other client), and reports any request it
       tried.

  It returns the violations, `[]` for none. `inventory/0` is every internal target that
  can change something, across the registered domains.
  """

  alias AshEnterprise.Integration.Nango.Proxy
  alias AshEnterprise.Repo

  @blocked __MODULE__.Blocked

  @doc "Every `{resource, action}` declared internal and not read-only, in the registered domains."
  @spec inventory() :: [{Ash.Resource.t(), atom()}]
  def inventory do
    for domain <- Application.get_env(:ash_enterprise, :ash_domains),
        resource <- Ash.Domain.Info.resources(domain),
        AshAgent.Effects in Spark.extensions(resource),
        effect <- AshAgent.Effects.Info.effects(resource),
        not effect.open_world? and not effect.read_only? do
      {resource, effect.name}
    end
  end

  @doc """
  Blocks outbound HTTP for the calling test: every request through the Nango façade or
  any other `Req` client is answered `599` and recorded. Call it from `setup`.
  """
  def block! do
    previous = Req.default_options()
    Req.default_options(Keyword.put(previous, :plug, {Req.Test, @blocked}))
    ExUnit.Callbacks.on_exit(fn -> Req.default_options(previous) end)

    secret = System.get_env("NANGO_SECRET_KEY")
    System.put_env("NANGO_SECRET_KEY", "nango-test-secret-not-a-real-key")

    ExUnit.Callbacks.on_exit(fn ->
      if secret,
        do: System.put_env("NANGO_SECRET_KEY", secret),
        else: System.delete_env("NANGO_SECRET_KEY")
    end)

    test = self()

    blocked = fn conn ->
      send(test, {:outbound_request, conn.method, conn.host, conn.request_path})
      Plug.Conn.send_resp(conn, 599, "outbound HTTP is blocked in the no-network contract")
    end

    Req.Test.set_req_test_to_shared()
    Req.Test.stub(@blocked, blocked)
    Req.Test.stub(Proxy, blocked)
    :ok
  end

  @doc "The contract's violations for `resource`'s `action`, run as `actor` in `tenant`."
  @spec check(Ash.Resource.t(), atom(), keyword()) :: [String.t()]
  def check(resource, action_name, opts) do
    action = Ash.Resource.Info.action(resource, action_name)
    inputs = resource |> Ash.Generator.action_input(action_name) |> ExUnitProperties.pick()
    name = "#{inspect(resource)}.#{action_name}"

    {:error, {:rolled_back, hooks}} =
      Repo.transaction(fn ->
        subject = build(resource, action, inputs, opts)
        hooks = transaction_hooks(subject)
        _ = run(subject)
        Repo.rollback({:rolled_back, hooks})
      end)

    hook_violations = for kind <- hooks, do: "#{name} attaches a #{kind} hook"

    request_violations =
      for {method, host, path} <- drain_requests() do
        "#{name} called out: #{method} #{host}#{path}"
      end

    hook_violations ++ request_violations
  end

  defp build(resource, %{type: :create, name: name}, inputs, opts),
    do: Ash.Changeset.for_create(resource, name, inputs, opts)

  defp build(resource, %{type: :update, name: name}, inputs, opts),
    do: resource |> struct() |> Ash.Changeset.for_update(name, inputs, opts)

  defp build(resource, %{type: :destroy, name: name}, inputs, opts),
    do: resource |> struct() |> Ash.Changeset.for_destroy(name, inputs, opts)

  defp build(resource, %{type: :action, name: name}, inputs, opts),
    do: Ash.ActionInput.for_action(resource, name, inputs, opts)

  # An update or destroy built on a record that was never loaded cannot run; its
  # hooks are still the ones its changes attach, which is what the first half checks.
  defp run(%Ash.Changeset{action_type: :create} = changeset),
    do: safely(fn -> Ash.create(changeset) end)

  defp run(%Ash.Changeset{}), do: :not_run
  defp run(%Ash.ActionInput{} = input), do: safely(fn -> Ash.run_action(input) end)

  defp safely(fun) do
    fun.()
  rescue
    error -> {:raised, error}
  catch
    kind, reason -> {kind, reason}
  end

  defp transaction_hooks(subject) do
    for kind <- [:before_transaction, :after_transaction, :around_transaction],
        Map.get(subject, kind, []) != [],
        do: kind
  end

  defp drain_requests do
    receive do
      {:outbound_request, method, host, path} -> [{method, host, path} | drain_requests()]
    after
      0 -> []
    end
  end
end
