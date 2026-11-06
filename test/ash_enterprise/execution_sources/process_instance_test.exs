defmodule AshEnterprise.ExecutionSources.ProcessInstanceTest do
  @moduledoc """
  How a process run's status reads on the trace: only a completed run succeeded, and a
  status the source does not know reads as uncertain, never as a pass.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.ExecutionSources.ProcessInstance

  test "each status the runtime reports reads as what it is" do
    assert ProcessInstance.status(:running) == :running
    assert ProcessInstance.status(:completed) == :succeeded
    assert ProcessInstance.status(:failed) == :failed
    assert ProcessInstance.status(:errored) == :failed
    assert ProcessInstance.status(:cancelled) == :cancelled
    assert ProcessInstance.status(:superseded) == :cancelled
  end

  test "a status it does not know, or none, is uncertain" do
    for status <- [:suspended, :unknown, nil, "completed"],
        do: assert(ProcessInstance.status(status) == :uncertain)
  end
end
