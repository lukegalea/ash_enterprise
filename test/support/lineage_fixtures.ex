defmodule AshEnterprise.Test.LineageFixtures do
  @moduledoc """
  Lineage test helpers: switching the store to `:inline` for a test, and
  building RunEvents the way `ash_open_lineage` builds them.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @store AshEnterprise.Lineage.Store

  @doc """
  Records lineage inline (in the test's own sandbox) until the test exits.
  Call from `setup` of an `async: false` test only: the mode is global.
  """
  def inline_store! do
    previous = Application.get_env(:ash_enterprise, @store)
    Application.put_env(:ash_enterprise, @store, Keyword.put(previous || [], :mode, :inline))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_enterprise, @store, previous),
        else: Application.delete_env(:ash_enterprise, @store)
    end)
  end

  @doc """
  Runs `fun` with the store off, so fixtures (seeding a tenant, a role)
  leave no lineage of their own. For `async: false` tests only.
  """
  def quietly(fun) do
    previous = Application.get_env(:ash_enterprise, @store) || []
    Application.put_env(:ash_enterprise, @store, Keyword.put(previous, :mode, :off))

    try do
      fun.()
    after
      Application.put_env(:ash_enterprise, @store, previous)
    end
  end

  @doc """
  One RunEvent as `AshOpenLineage` builds it. Options: `:run_id`,
  `:correlation_id`, `:inputs`, `:outputs`, `:at`, `:error`.
  """
  def event(type, namespace, name, opts \\ []) do
    AshOpenLineage.Event.run_event(
      [
        event_type: type,
        job_namespace: namespace,
        job_name: name,
        run_id: Keyword.fetch!(opts, :run_id),
        correlation_id: opts[:correlation_id],
        inputs: opts[:inputs] || [],
        outputs: opts[:outputs] || [],
        event_time: opts[:at],
        producer_name: "#{namespace}.#{name}"
      ]
      |> then(fn base ->
        if type == :fail,
          do: Keyword.put(base, :error_message, opts[:error] || "boom"),
          else: base
      end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    )
  end
end
