defmodule AshEnterprise.Mdm.BulkImport do
  @moduledoc """
  A large CSV in through the MDM staged import: the upload is kept as a file on
  the server, never as rows in the wizard's memory, and the batch worker lands
  it a chunk at a time (docs/runbooks/bulk-import.md).

  The path, in order:

    1. `store_upload/1` copies the wizard's temp file into the upload store and
       names it by a fresh id (the file LiveView wrote is deleted when the
       upload is consumed).
    2. `inspect_upload/1` reads the header, a ten-row sample and the row count.
       A file over `max_rows` is refused here, before anything lands.
    3. `start/3` opens the batch **as the person** (their grant on
       `ImportBatch.open` decides; a refusal lands nothing) and enqueues
       `AshEnterprise.Mdm.BatchWorker` with the batch id and the upload id.
    4. The worker calls `land/3`: rows land `chunk_size` at a time through
       `AshEnterprise.Mdm.Landing.land_row/4`, a slice per job execution,
       then staging reads them.

  Landing is the platform's write, under the batch's own tenant: the row key
  is the row's position in the file (`upload-<index>`), so landing the same
  file again under the same dataset re-observes the same identities and
  bizev's temporal landing writes nothing for unchanged content.

  A row that cannot land is not a failed import. It is recorded as an
  `AshEnterprise.Mdm.ImportRowRefusal` with its spreadsheet row number and a
  reason that names the rule, not the row's values, and the rest land:

    * a row whose field count differs from the header's is malformed;
    * a row whose `residency_column` (default `"residency"`, matched without
      regard to case) declares a residency the landing region does not admit
      is refused by bizev's admission at land (ADR 0042).

  Landing runs in slices of about a minute (`slice_ms`), the job snoozing
  between them, so no execution runs long enough for Oban's Lifeline to take
  it for an orphan and start a second copy. Each slice is a telemetry span
  (`land_event/0`); its stop event carries the duration, the landed and
  refused counts so far, and whether landing is done.

  Configuration lives under `config :ash_enterprise, AshEnterprise.Mdm.BulkImport`:
  `max_rows`, `max_file_size`, `chunk_size`, `slice_ms`, `residency_column` and
  `upload_dir`.
  """

  alias AshEnterprise.Mdm.{ImportBatch, ImportRowRefusal, Landing}

  require Logger

  @sample_count 10

  # `[:ash_enterprise, :mdm, :bulk_import, :land, :start | :stop | :exception]`,
  # once per slice: the stop event carries the slice's duration, the batch's
  # landed and refused counts so far, and `done?`.
  @land_event [:ash_enterprise, :mdm, :bulk_import, :land]

  @doc "The telemetry span prefix `land/3` emits, once per slice."
  @spec land_event() :: [atom()]
  def land_event, do: @land_event

  @doc "The row cap: a file with more data rows is refused before any land."
  @spec max_rows() :: pos_integer()
  def max_rows, do: config(:max_rows, 50_000)

  @doc "The upload size limit in bytes."
  @spec max_file_size() :: pos_integer()
  def max_file_size, do: config(:max_file_size, 30_000_000)

  @doc "How many rows land between two progress writes."
  @spec chunk_size() :: pos_integer()
  def chunk_size, do: config(:chunk_size, 1_000)

  @doc """
  How long one slice of landing runs before the worker snoozes and carries on
  (milliseconds; at least one chunk lands per slice).
  """
  @spec slice_ms() :: non_neg_integer()
  def slice_ms, do: config(:slice_ms, 60_000)

  @doc "The header (matched without regard to case) a row declares its residency in."
  @spec residency_column() :: String.t()
  def residency_column, do: config(:residency_column, "residency")

  defp upload_dir,
    do: config(:upload_dir, Path.join(System.tmp_dir!(), "ash_enterprise_imports"))

  defp config(key, default) do
    :ash_enterprise |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  # -- the upload store -------------------------------------------------------

  # Sobelow reads `@sobelow_skip` out of the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see AshEnterprise.Audit.Export).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc """
  Copies `temp_path` (the file LiveView wrote for this socket's own upload)
  into the upload store and returns the id it is kept under.
  """
  # `temp_path` comes from consume_uploaded_entries/3, never from a client;
  # the destination is built from a fresh uuid.
  @sobelow_skip ["Traversal.FileModule"]
  @spec store_upload(Path.t()) :: {:ok, Ecto.UUID.t()} | {:error, File.posix()}
  def store_upload(temp_path) do
    upload_id = Ash.UUID.generate()
    File.mkdir_p!(upload_dir())

    case File.cp(temp_path, Path.join(upload_dir(), upload_id <> ".csv")) do
      :ok -> {:ok, upload_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Removes a stored upload. Unknown ids are ignored."
  # The path is built from a cast uuid (`upload_path/1`).
  @sobelow_skip ["Traversal.FileModule"]
  @spec discard(String.t() | nil) :: :ok
  def discard(upload_id) do
    with {:ok, path} <- upload_path(upload_id), do: File.rm(path)
    :ok
  end

  @doc """
  The stored file for `upload_id`. Only an id that casts as a uuid builds a
  path, so no caller can name a file outside the store.
  """
  @spec upload_path(term()) :: {:ok, Path.t()} | {:error, :unknown_upload}
  def upload_path(upload_id) do
    with {:ok, id} <- Ecto.UUID.cast(upload_id),
         path = Path.join(upload_dir(), id <> ".csv"),
         true <- File.regular?(path) do
      {:ok, path}
    else
      _ -> {:error, :unknown_upload}
    end
  end

  # -- inspecting ---------------------------------------------------------------

  @doc """
  The upload's header, its first ten rows (as maps) and its data-row count.
  Streams the file: the rows are counted, never held.

  Refuses `{:error, {:over_cap, max}}` when the file has more data rows than
  `max_rows` (pass `max_rows:` to override), and `{:error, message}` when the
  file has no header row or is not valid CSV.
  """
  @spec inspect_upload(String.t(), keyword()) ::
          {:ok, %{headers: [String.t()], sample: [map()], row_count: non_neg_integer()}}
          | {:error, term()}
  def inspect_upload(upload_id, opts \\ []) do
    cap = Keyword.get(opts, :max_rows, max_rows())

    with {:ok, path} <- upload_path(upload_id) do
      path
      |> records()
      |> Enum.reduce_while({nil, [], 0}, &tally_record(&1, &2, cap))
      |> case do
        {:over_cap, cap} ->
          {:error, {:over_cap, cap}}

        {nil, _, _} ->
          {:error, "the file has no header row"}

        {headers, sample, count} ->
          {:ok, %{headers: headers, sample: Enum.reverse(sample), row_count: count}}
      end
    end
  rescue
    error in NimbleCSV.ParseError -> {:error, "the file is not valid CSV: " <> error.message}
  end

  defp tally_record({fields, :header}, {nil, sample, count}, _cap),
    do: {:cont, {fields, sample, count}}

  defp tally_record({fields, _index}, {headers, sample, count}, cap) do
    cond do
      blank?(fields) ->
        {:cont, {headers, sample, count}}

      count + 1 > cap ->
        {:halt, {:over_cap, cap}}

      length(sample) < @sample_count ->
        {:cont, {headers, [row_map(headers, fields) | sample], count + 1}}

      true ->
        {:cont, {headers, sample, count + 1}}
    end
  end

  # -- starting -----------------------------------------------------------------

  @doc """
  Opens a batch for `upload_id` as `actor` and enqueues the worker that lands
  and stages it. Nothing lands here.

  `input` is `%{mapping_id: ..., source_slug: ...}`. Refuses before opening a
  batch when the upload is unknown or over the cap; a person without a grant
  to open the batch gets `Ash.Error.Forbidden` and nothing is enqueued.
  """
  @spec start(String.t(), map(), keyword()) ::
          {:ok, ImportBatch.t(), Oban.Job.t()} | {:error, term()}
  def start(upload_id, input, opts) do
    actor = Keyword.fetch!(opts, :actor)
    tenant = Keyword.fetch!(opts, :tenant)

    with {:ok, _summary} <- inspect_upload(upload_id),
         {:ok, batch} <-
           ImportBatch
           |> Ash.Changeset.for_create(:open, input, tenant: tenant, actor: actor)
           |> Ash.create(),
         {:ok, job} <-
           %{"batch_id" => batch.id, "tenant" => batch.organization_id, "upload_id" => upload_id}
           |> AshEnterprise.Mdm.BatchWorker.new()
           |> Oban.insert() do
      {:ok, batch, job}
    end
  end

  # -- landing -------------------------------------------------------------------

  @doc """
  Lands the rows of `upload_id` for `batch`, under the batch's tenant and
  dataset, a chunk at a time, and records each row that does not land.
  Called by the batch worker.

  One call is one slice: it lands chunks until `slice_ms` has passed (at
  least one chunk), and after each chunk writes the progress onto the batch's
  `counts` (`landed`, `refused`, and `land_cursor`, the number of data rows
  done). A slice that stops before the end returns `{:more, totals}`, and the
  next call carries on from the cursor. Each slice stays well inside the time
  after which Oban's Lifeline would take a running job for an orphan and start
  it again.

  When the last row is done, `landed_at` is written too, and the call returns
  `{:ok, %{landed: n, refused: m, as_of: landed_at}}`. Staging reads as of that
  instant. A call for a batch that already has `landed_at` returns the same
  without opening the file, so a retried job never lands a file twice.
  """
  @spec land(ImportBatch.t(), String.t(), keyword()) ::
          {:ok, %{landed: non_neg_integer(), refused: non_neg_integer(), as_of: DateTime.t()}}
          | {:more, %{landed: non_neg_integer(), refused: non_neg_integer()}}
          | {:error, term()}
  def land(%ImportBatch{} = batch, upload_id, opts \\ []) do
    counts = batch.counts || %{}

    case counts["landed_at"] do
      nil -> land_slice(batch, upload_id, Keyword.get(opts, :slice_ms, slice_ms()))
      landed_at -> {:ok, landed_totals(counts, landed_at)}
    end
  end

  defp land_slice(batch, upload_id, slice_ms) do
    with {:ok, path} <- upload_path(upload_id) do
      stream = records(path)

      case Enum.take(stream, 1) do
        [{headers, :header}] -> land_span(batch, stream, headers, slice_ms)
        _ -> {:error, "the file has no header row"}
      end
    end
  end

  defp land_span(batch, stream, headers, slice_ms) do
    metadata = %{batch_id: batch.id, tenant: batch.organization_id}

    :telemetry.span(@land_event, metadata, fn ->
      result = land_from_cursor(batch, stream, headers, slice_ms)
      {result, Map.merge(metadata, result_metadata(result))}
    end)
  end

  defp land_from_cursor(batch, stream, headers, slice_ms) do
    counts = batch.counts || %{}
    residency_at = residency_index(headers)
    deadline = System.monotonic_time(:millisecond) + slice_ms

    progress = %{
      batch: batch,
      cursor: counts["land_cursor"] || 0,
      landed: counts["landed"] || 0,
      refused: counts["refused"] || 0
    }

    stream
    |> Stream.drop(1)
    |> Stream.reject(fn {fields, _index} -> blank?(fields) end)
    |> Stream.drop(progress.cursor)
    |> Stream.chunk_every(chunk_size())
    |> Enum.reduce_while({:done, progress}, fn chunk, {_state, progress} ->
      {landed, refusals} = land_chunk(progress.batch, headers, residency_at, chunk)
      record_refusals!(progress.batch, refusals)

      progress =
        save_progress!(%{
          progress
          | cursor: progress.cursor + length(chunk),
            landed: progress.landed + landed,
            refused: progress.refused + length(refusals)
        })

      if System.monotonic_time(:millisecond) >= deadline,
        do: {:halt, {:more, progress}},
        else: {:cont, {:done, progress}}
    end)
    |> case do
      {:more, progress} ->
        {:more, %{landed: progress.landed, refused: progress.refused}}

      {:done, progress} ->
        landed_at = DateTime.utc_now()
        save_progress!(progress, %{"landed_at" => DateTime.to_iso8601(landed_at)})
        {:ok, %{landed: progress.landed, refused: progress.refused, as_of: landed_at}}
    end
  end

  # The batch's counters as landing leaves them. `begin_staging` moves an open
  # batch into the staging lane, where the board shows it while it lands.
  defp save_progress!(progress, extra \\ %{}) do
    counts =
      (progress.batch.counts || %{})
      |> Map.merge(%{
        "land_cursor" => progress.cursor,
        "landed" => progress.landed,
        "refused" => progress.refused
      })
      |> Map.merge(extra)

    tenant = progress.batch.organization_id

    batch =
      progress.batch
      |> Ash.Changeset.for_update(:begin_staging, %{}, tenant: tenant, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:counts, counts)
      |> Ash.update!(tenant: tenant, authorize?: false)

    %{progress | batch: batch}
  end

  defp landed_totals(counts, landed_at) do
    {:ok, as_of, _offset} = DateTime.from_iso8601(landed_at)
    %{landed: counts["landed"] || 0, refused: counts["refused"] || 0, as_of: as_of}
  end

  defp result_metadata({state, totals}),
    do: %{landed: totals.landed, refused: totals.refused, done?: state == :ok}

  defp land_chunk(batch, headers, residency_at, chunk) do
    Enum.reduce(chunk, {0, []}, fn {fields, index}, {landed, refusals} ->
      case land_one(batch, headers, residency_at, fields, index) do
        :ok -> {landed + 1, refusals}
        {:refused, reason} -> {landed, [%{row_number: index + 2, reason: reason} | refusals]}
      end
    end)
  end

  defp land_one(_batch, headers, _residency_at, fields, _index)
       when length(fields) != length(headers) do
    {:refused, "malformed row: #{length(fields)} fields where the header has #{length(headers)}"}
  end

  defp land_one(batch, headers, residency_at, fields, index) do
    tag = residency_tag(fields, residency_at)

    case Landing.land_row(batch.organization_id, batch.source_slug, row_map(headers, fields),
           row_key: "upload-#{index}",
           residency_tag: tag
         ) do
      {:ok, _landed} -> :ok
      {:error, error} -> {:refused, refusal_reason(error, tag)}
    end
  end

  defp record_refusals!(_batch, []), do: :ok

  defp record_refusals!(batch, refusals) do
    refusals
    |> Enum.map(&Map.put(&1, :batch_id, batch.id))
    |> Ash.bulk_create!(ImportRowRefusal, :record,
      tenant: batch.organization_id,
      authorize?: false,
      return_errors?: true,
      stop_on_error?: true
    )

    :ok
  end

  # The reason names the rule the row broke. It never quotes the row's values:
  # only the residency the row itself declared, cut short.
  defp refusal_reason(error, tag) do
    errors = flatten(error)

    cond do
      Enum.any?(errors, &match?(%AshDiscreteBusinessEvents.SourceRecord.AdmissionRefused{}, &1)) ->
        "inadmissible region: residency #{inspect(String.slice(tag || "", 0, 32))} " <>
          "is not admitted into the landing region"

      Enum.any?(errors, &match?(%AshDiscreteBusinessEvents.SourceRecord.BackdatedLanding{}, &1)) ->
        "this row's dataset already holds a newer observation of it"

      true ->
        Logger.warning(
          "bulk import: a row did not land (#{inspect(Enum.map(errors, & &1.__struct__))})"
        )

        "refused at land"
    end
  end

  defp flatten(%{errors: errors}) when is_list(errors), do: Enum.flat_map(errors, &flatten/1)
  defp flatten(error), do: [error]

  # -- parsing ---------------------------------------------------------------------

  # `{fields, :header}` first, then `{fields, index}` per record (index 0 is the
  # first data record). Streamed: NimbleCSV joins a quoted field across lines.
  # The path comes from `upload_path/1`.
  @sobelow_skip ["Traversal.FileModule"]
  defp records(path) do
    path
    |> File.stream!(:line)
    |> NimbleCSV.RFC4180.parse_stream(skip_headers: false)
    |> Stream.with_index(-1)
    |> Stream.map(fn
      {fields, -1} -> {Enum.map(fields, &strip_bom/1), :header}
      {fields, index} -> {fields, index}
    end)
  end

  defp strip_bom("﻿" <> rest), do: rest
  defp strip_bom(field), do: field

  defp blank?([]), do: true
  defp blank?([""]), do: true
  defp blank?(_fields), do: false

  defp row_map(headers, fields), do: Map.new(Enum.zip(headers, fields))

  defp residency_index(headers) do
    wanted = String.downcase(residency_column())
    Enum.find_index(headers, &(String.downcase(String.trim(&1)) == wanted))
  end

  defp residency_tag(_fields, nil), do: nil

  defp residency_tag(fields, at) do
    case fields |> Enum.at(at, "") |> String.trim() |> String.downcase() do
      "" -> nil
      tag -> tag
    end
  end
end
