defmodule AshEnterprise.Faults do
  @moduledoc """
  Named fault points: places in production code where a test can make the process fail.

  A durable flow is a sequence of commits, and what has to be true of it is what happens when
  the process doing it dies *between* two of them. That moment cannot be reached by mocking a
  dependency or raising from a test: the code that commits is the code that must stop. So the
  code says where it may be stopped, by name:

      record_claim!(visit)
      AshEnterprise.Faults.point(:after_claim)
      notify_clinic!(visit)

  and a test arms that name:

      Faults.arm(:after_claim, :kill)

  ## A function, and a no-op outside `:test`

  `point/1` is an ordinary function, not a macro, so a fault point reads like the call it is and
  a caller needs no `require`. Whether it does anything is decided by application config at
  compile time:

      config :ash_enterprise, AshEnterprise.Faults, enabled?: true

  is set in `config/test.exs`. The showcase's demo flag compiles them in as well
  (`config :ash_enterprise, AshEnterprise.Showcase, fault_controls?: true`, see
  `AshEnterprise.Showcase`), so its fault panel can arm them; `config/dev.exs` sets it and
  production never does. Everywhere else `point/1` compiles to `:ok` and `arm/3` refuses,
  so a fault point left in a hot path costs a local function call and can never fire.

  ## What a fault does

    * `:raise` raises `AshEnterprise.Faults.Fault`, which an Oban job records as an error.
    * `:exit` exits the calling process with `{:fault, name}`.
    * `:kill` kills the calling process outright (`Process.exit(self(), :kill)`), which no
      `rescue`, `catch` or `after` in the caller can observe: the nearest thing to the node
      dying that a test can do without stopping the node.

  An armed point fires `times` times (default once) across every process, then goes quiet, so
  a retry after the fault runs the real path without the test racing to disarm it. `skip: n`
  lets the first `n` hits through before it fires: "the second model call fails".

  Armed points live in the application environment, so they are global to the node: tests that
  arm them must be `async: false`.
  """

  @type action :: :raise | :exit | :kill
  @type arm_opt ::
          {:times, pos_integer() | :infinity} | {:skip, non_neg_integer()} | {:notify, pid()}

  @enabled? Application.compile_env(:ash_enterprise, [__MODULE__, :enabled?], false) or
              Application.compile_env(
                :ash_enterprise,
                [AshEnterprise.Showcase, :fault_controls?],
                false
              )

  @doc "Whether fault points were compiled in: under the test configuration or the showcase's demo flag."
  @spec enabled?() :: boolean()
  def enabled?, do: @enabled?

  if @enabled? do
    alias AshEnterprise.Faults.Fault

    @armed_key :__armed_faults__

    @doc """
    A named fault point. Does nothing unless a test armed `name`; then raises, exits or kills
    the calling process as armed.
    """
    @spec point(atom()) :: :ok
    def point(name) when is_atom(name) do
      case Map.fetch(armed(), name) do
        {:ok, fault} -> maybe_fire(name, fault)
        :error -> :ok
      end
    end

    @doc """
    Arms `name` with `action`.

    Options:

      * `:times` — how many times it fires before going quiet. A positive integer (default
        `1`) or `:infinity`.
      * `:skip` — how many hits pass before the first fault (default `0`).
      * `:notify` — a pid sent `{:fault_fired, name, pid}` just before the fault fires, naming
        the process that is about to fail.
    """
    @spec arm(atom(), action(), [arm_opt()]) :: :ok
    def arm(name, action, opts \\ [])
        when is_atom(name) and action in [:raise, :exit, :kill] do
      fault = %{
        action: action,
        skip: skips(Keyword.get(opts, :skip, 0)),
        remaining: counter(Keyword.get(opts, :times, 1)),
        notify: opts[:notify]
      }

      Application.put_env(:ash_enterprise, @armed_key, Map.put(armed(), name, fault))
    end

    @doc "Disarms `name`. A point that was never armed is already disarmed."
    @spec disarm(atom()) :: :ok
    def disarm(name) when is_atom(name) do
      Application.put_env(:ash_enterprise, @armed_key, Map.delete(armed(), name))
    end

    @doc "Disarms every point."
    @spec disarm_all() :: :ok
    def disarm_all, do: Application.delete_env(:ash_enterprise, @armed_key)

    defp armed, do: Application.get_env(:ash_enterprise, @armed_key, %{})

    defp counter(:infinity), do: :infinity

    defp counter(times) when is_integer(times) and times > 0 do
      ref = :atomics.new(1, signed: true)
      :atomics.put(ref, 1, times)
      ref
    end

    defp skips(0), do: nil
    defp skips(skip) when is_integer(skip) and skip > 0, do: counter(skip)

    # The decrement is atomic across processes, so two jobs reaching a point armed `times: 1`
    # at the same moment fire it once between them, not twice. Skipped hits are counted the
    # same way.
    defp maybe_fire(name, %{skip: skip} = fault) when skip != nil do
      if :atomics.sub_get(skip, 1, 1) >= 0, do: :ok, else: maybe_fire(name, %{fault | skip: nil})
    end

    defp maybe_fire(name, %{remaining: :infinity} = fault), do: fire(name, fault)

    defp maybe_fire(name, %{remaining: ref} = fault) do
      if :atomics.sub_get(ref, 1, 1) >= 0, do: fire(name, fault), else: :ok
    end

    defp fire(name, fault) do
      if is_pid(fault.notify), do: send(fault.notify, {:fault_fired, name, self()})

      case fault.action do
        :raise -> raise Fault, point: name
        :exit -> exit({:fault, name})
        :kill -> Process.exit(self(), :kill)
      end

      :ok
    end
  else
    @doc "A named fault point. Compiled out: fault points fire only under the test configuration or the showcase's demo flag."
    @spec point(atom()) :: :ok
    def point(name) when is_atom(name), do: :ok

    @doc false
    def arm(_name, _action, _opts \\ []), do: raise(ArgumentError, compiled_out())

    @doc false
    def disarm(_name), do: :ok

    @doc false
    def disarm_all, do: :ok

    defp compiled_out,
      do:
        "fault points are compiled out; config/test.exs or the showcase's demo flag compiles them in"
  end
end
