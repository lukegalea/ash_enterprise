defmodule AshEnterprise.Ingestion.TapWorker do
  @moduledoc """
  Oban wrapper job for one ingestion pipeline (epic E1, ADR 0010).

  Runs the configured tap for the named pipeline, parses its Singer output
  (RECORD / STATE lines) and lands each record immutably as an
  `AshEnterprise.Ingestion.SourceObject`, stamped with the run's final STATE as
  its cursor. Re-running the same pass is idempotent: `land` upserts on the
  source identity, refreshing payload and cursor in place.

  Job args carry only the pipeline *name*. Commands, credentials and Nango
  connection references come from deployment config (`:pipelines` below) — the
  wire never selects a command, and a provider connection id is resolved from
  linked-account data at the vertical layer (ADR 0011), never from args.

      config :ash_enterprise, AshEnterprise.Ingestion,
        pipelines: %{
          "app_db" => %{
            "command" => "meltano invoke tap-postgres --config ...",
            "external_system" => "postgres"
          }
        }

  ## In-app fixture sources (epic E4)

  A pipeline whose config declares `"fixture" => true` has no `"command"`:
  the runner is bypassed and `AshEnterprise.Ingestion.FixtureTap`'s Singer
  output is used verbatim. Parsing and landing are identical to a shelled-out
  tap — a fixture run is a real pipeline run, lineage events included.

      "calendar_dev" => %{"fixture" => true, "external_system" => "calendar"}

  Enqueue: `AshEnterprise.Ingestion.TapWorker.new(%{"pipeline" => "app_db"}) |> Oban.insert()`.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 5, unique: [period: 30]

  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Ingestion.TapRunner

  @impl true
  def perform(%Oban.Job{args: %{"pipeline" => name}}) do
    case pipeline_config(name) do
      {:ok, config} -> run_pipeline(name, config)
      :error -> {:error, "unknown ingestion pipeline: #{inspect(name)}"}
    end
  end

  def perform(%Oban.Job{args: args}) do
    {:error, "tap job requires a \"pipeline\" argument, got: #{inspect(args)}"}
  end

  defp pipeline_config(name) do
    :ash_enterprise
    |> Application.get_env(AshEnterprise.Ingestion, [])
    |> Keyword.get(:pipelines, %{})
    |> Map.fetch(name)
  end

  defp run_pipeline(name, config) do
    external_system = Map.fetch!(config, "external_system")

    # In-app fixture sources (epic E4) declare "fixture" and carry no command:
    # the runner is bypassed and the fixture's Singer output is used verbatim.
    # See AshEnterprise.Ingestion.FixtureTap.
    tap_kind =
      if Map.has_key?(config, "fixture") do
        "fixture"
      else
        "tap_postgres"
      end

    job_name = "#{tap_kind}.#{name}"
    inputs = ["#{external_system}.source"]
    outputs = ["#{external_system}.ingestion_source_objects"]

    # One run id for the whole pipeline run — the same id the START event used,
    # so a FAIL attaches to the run it broke.
    run_id = AshEnterprise.Platform.Correlation.id()

    with :ok <-
           AshEnterprise.Lineage.ingestion_event(:start, "ingestion", job_name,
             run_id: run_id,
             inputs: inputs,
             outputs: outputs
           ),
         {:ok, output} <- tap_output(config),
         {:ok, parsed} <- parse_singer(output, "pipeline #{inspect(name)}") do
      land(parsed.records, external_system, parsed.state, name)

      AshEnterprise.Lineage.ingestion_event(:complete, "ingestion", job_name,
        run_id: run_id,
        inputs: inputs,
        outputs: outputs
      )

      # Deterministic proof of work: the job's own result reports what landed.
      {:ok, %{records: length(parsed.records), external_system: external_system}}
    else
      {:error, reason} = error ->
        # Hole rule (ADR 0012): a broken pipeline is a FAIL event, not silence.
        AshEnterprise.Lineage.ingestion_event(:fail, "ingestion", job_name,
          run_id: run_id,
          reason: reason
        )

        error
    end
  end

  # Where a pipeline's Singer output comes from: the fixture's in-process
  # output for `"fixture" => true` pipelines, the configured runner (a shell
  # out) for everything else.
  defp tap_output(config) do
    if Map.has_key?(config, "fixture") do
      {:ok, AshEnterprise.Ingestion.FixtureTap.singer_output()}
    else
      TapRunner.runner().run(Map.fetch!(config, "command"))
    end
  end

  defp parse_singer(output, context) do
    records =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce([], fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{"type" => "RECORD", "record" => record} = event} ->
            [%{record: record, stream: event["stream"], time: event_time(event)} | acc]

          {:ok, %{"type" => "STATE", "value" => value}} ->
            [{:state, value} | acc]

          {:ok, _other} ->
            acc

          {:error, _} ->
            # Taps may emit progress on stdout; only whole JSON lines count.
            acc
        end
      end)

    records = Enum.reverse(records)

    state =
      records
      |> Enum.filter(&match?({:state, _}, &1))
      |> List.last()
      |> case do
        {:state, value} -> value
        nil -> nil
      end

    {:ok, %{records: Enum.filter(records, &is_map/1), state: state}}
  rescue
    e ->
      {:error, "unparseable singer output for #{context}: #{Exception.message(e)}"}
  end

  defp event_time(%{"time_recorded" => t}) when is_binary(t), do: t
  defp event_time(_), do: nil

  defp land(records, external_system, state, _pipeline) do
    cursor = state
    now = DateTime.utc_now()

    Enum.each(records, fn %{record: record, stream: stream, time: time} ->
      fetched_at = parse_time(time) || now

      SourceObject.land!(
        %{
          external_system: external_system,
          external_id: external_id(record),
          raw_payload: record,
          source_metadata: %{"stream" => stream},
          cursor: cursor,
          fetched_at: fetched_at
        },
        authorize?: false
      )
    end)
  end

  # The record is opaque; the id it must carry is the tap's contract. Singer
  # taps tag their replication key, otherwise the conventional `id`.
  defp external_id(record) do
    case record do
      %{"_sdc_primary_key" => [k | _]} -> record |> Map.get(k) |> to_string()
      %{"id" => id} -> to_string(id)
      _ -> raise "tap record has neither _sdc_primary_key nor id: #{inspect(Map.keys(record))}"
    end
  end

  defp parse_time(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
