defmodule AshEnterprise.Ingestion.TapRunner.Exec do
  @moduledoc """
  Default `AshEnterprise.Ingestion.TapRunner`: runs the pipeline's command in a
  shell (`System.shell/2`), capturing stdout. The command string comes from the
  deployment's pipeline configuration, never from job args — an Oban arg can only
  *name* a configured pipeline, not compose one.
  """

  @behaviour AshEnterprise.Ingestion.TapRunner

  # Sobelow reads `@sobelow_skip` out of the source AST (the export.ex
  # pattern); persisting it writes the value into the beam's attribute
  # chunk, which is what the scanner reads.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  # The command string comes from the deployment's pipeline configuration,
  # never from job args or a request — an Oban arg can only *name* a
  # configured pipeline, not compose one (see the moduledoc). Skipped by
  # name and locally: if request input ever reaches this function, that is
  # a real finding.
  @sobelow_skip ["DOS.Run"]
  @impl true
  def run(command) do
    case System.shell(command, into: "", stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:exit_status, status, output}}
    end
  end
end
