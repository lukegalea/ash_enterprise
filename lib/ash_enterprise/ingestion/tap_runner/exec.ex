defmodule AshEnterprise.Ingestion.TapRunner.Exec do
  @moduledoc """
  Default `AshEnterprise.Ingestion.TapRunner`: runs the pipeline's command in a
  shell (`System.shell/2`), capturing stdout. The command string comes from the
  deployment's pipeline configuration, never from job args — an Oban arg can only
  *name* a configured pipeline, not compose one.
  """

  @behaviour AshEnterprise.Ingestion.TapRunner

  @impl true
  def run(command) do
    case System.shell(command, into: "", stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:exit_status, status, output}}
    end
  end
end
