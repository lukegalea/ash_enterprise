defmodule AshEnterprise.Agents.OmpSupervisor do
  @moduledoc """
  Owns one `AshEnterprise.Agents.OmpSession` per live run, plus the
  `AshEnterprise.Agents.Registry` that names them by run id.

  A DynamicSupervisor because run starts are operator events, not boot-time
  facts (iron law #13: the process exists because a run is long-lived state,
  not because a page was viewed). Sessions are `:transient` children: they
  exit normally when their run reaches a terminal state and are never
  restarted into a second agent process for the same run — a dead session is
  a run waiting for an operator, not work to silently redo.
  """

  use DynamicSupervisor

  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
