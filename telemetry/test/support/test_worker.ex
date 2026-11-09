defmodule AshEnterprise.Telemetry.TestWorker do
  @moduledoc false
  use Oban.Worker, queue: :default

  alias AshEnterprise.Telemetry.Correlation

  require OpenTelemetry.Tracer

  @impl Oban.Worker
  def perform(%{args: %{"pid" => pid_string, "ref" => ref}}) do
    pid = pid_string |> String.to_charlist() |> :erlang.list_to_pid()

    OpenTelemetry.Tracer.with_span "inside.job" do
      send(pid, {:job_ran, ref, Correlation.current()})
    end

    :ok
  end

  def perform(_job), do: :ok
end

defmodule AshEnterprise.Telemetry.FailingWorker do
  @moduledoc false
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(_job), do: raise("job failure")
end
