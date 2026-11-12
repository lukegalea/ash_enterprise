defmodule AshEnterprise.Telemetry.TaskContext do
  @moduledoc """
  Carries the trace context, correlation id and acting user into a `Task` or any spawned
  process.

  Neither crosses a process boundary by itself, so work handed to a `Task` loses its
  place in the trace and its correlation:

      captured = TaskContext.capture()
      Task.async(fn -> TaskContext.run(captured, fn -> do_work() end) end)

  `bind/1` is the same thing for a function you hand over directly:

      Task.Supervisor.async_nolink(sup, TaskContext.bind(fn -> do_work() end))
  """

  alias AshEnterprise.Telemetry.Actor
  alias AshEnterprise.Telemetry.Settings
  alias OpenTelemetry.Ctx

  @enforce_keys [:ctx, :correlation]
  defstruct [:ctx, :correlation, actor: %{}]

  @type t :: %__MODULE__{ctx: term(), correlation: String.t() | nil, actor: map()}

  @doc "Captures the current trace context and correlation id."
  @spec capture() :: t()
  def capture do
    %__MODULE__{
      ctx: Ctx.get_current(),
      correlation: Settings.correlation().current(),
      actor: Actor.current()
    }
  end

  @doc "Runs `fun` under `captured`, then restores the previous context."
  @spec run(t(), (-> result)) :: result when result: var
  def run(%__MODULE__{} = captured, fun) when is_function(fun, 0) do
    token = Ctx.attach(captured.ctx)
    previous_actor = Actor.current()
    if map_size(captured.actor) > 0, do: Actor.restore(captured.actor)

    try do
      with_correlation(captured.correlation, fun)
    after
      Ctx.detach(token)
      Actor.restore(previous_actor)
    end
  end

  @doc "Wraps `fun` so it runs under the context captured now."
  @spec bind((-> result)) :: (-> result) when result: var
  def bind(fun) when is_function(fun, 0) do
    captured = capture()
    fn -> run(captured, fun) end
  end

  defp with_correlation(nil, fun), do: fun.()
  defp with_correlation(id, fun), do: Settings.correlation().with_correlation(id, fun)
end
