defmodule AshEnterprise.Journeys.FigureStore do
  @moduledoc """
  The audit copy of approved journey figures (`AshJourneys.FigureStore`), kept in the
  evidence store (`ash_evidence`). The stored bytes are the record (ADR 0067).

      FigureStore.archive("revoke_a_leavers_access", "en")
      FigureStore.fetch(file_sha256)

  ## What it writes

    * Each figure's bytes as one `AshEvidence.DocumentVersion` of kind `"journey-figure"`
      (`kind/0`), addressed by their SHA-256. The same bytes are one version, however
      many runs shot them.
    * One `AshEvidence.ParseRun` per execution of each figure, instrument `"playwright"`
      (`instrument/0`), closed `:ok`: its `config` names the run, commit, journey,
      version, declaration hash, locale, step, figure, browser build, environment, the
      file and raster hashes, the size, the highlight box as shot, and the SHA-256 of
      each Playwright trace file the run kept. Storing one execution's figure again adds
      nothing.
    * The highlight, when the figure has one, as a `:region` atom of that run on page 1,
      with `:px` geometry: the figure's size and the box normalised to it (clipped to the
      figure; the run's `config` keeps the box as shot).

  Trace files are recorded as hashes only; their bytes are never stored. Packets,
  evidence evaluations and assertions are not used: they model probabilistic
  adjudication, and a figure is a measured capture.

  ## What it refuses

  Only bytes the lock approved are stored. `put/2` refuses, and writes nothing, when the
  lock names no approved run of the journey in the locale, the figure is not in it, the
  run is not the approved one, or the bytes do not hash to the lock's `file_sha256`.
  `archive/3` stores the approved run only while it proves the journey now
  (`AshJourneys.Lock.verify/6`).

  ## Tenancy

  The versions are untenanted. Figures come only from the seeded world (ADR 0086), so they
  are no organization's data, and they document the product for every tenant.
  """

  @behaviour AshJourneys.FigureStore

  require Ash.Query

  # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see AshEnterprise.Guides).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  alias AshEvidence.{DocumentVersion, ParseRun}
  alias AshJourneys.{Lock, Manifest}

  @kind "journey-figure"
  @instrument "playwright"
  @digest ~r/\A[0-9a-f]{64}\z/

  @doc "The document version kind figures are stored as."
  def kind, do: @kind

  @doc "The parse run instrument an execution is recorded as."
  def instrument, do: @instrument

  @doc """
  Stores the figures of the run that proves journey `id` in `locale` now, read from
  `priv/journeys/`. Returns each figure's reference (its `file_sha256`), in step order.

  Options: `:traces`, paths of the Playwright trace files the run kept (only their
  hashes are recorded), and `:root`, the project root (the app directory by default).
  """
  @spec archive(String.t(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def archive(id, locale, opts \\ []) do
    root = Keyword.get_lazy(opts, :root, &root/0)

    with {:ok, journey} <- declared(id),
         {:ok, lock} <- Lock.read(root),
         {:ok, _entry, manifest} <- current(root, lock, id, journey, locale),
         {:ok, traces} <- trace_digests(Keyword.get(opts, :traces, [])) do
      dir = Lock.approved_dir(root, locale, id)

      manifest.steps
      |> Enum.flat_map(fn step -> Enum.map(step.figures, &{step, &1}) end)
      |> all_ok(&archive_figure(lock, dir, manifest, &1, traces))
    end
  end

  # The lock's own record of where the approved file is: the path is never the caller's.
  @sobelow_skip ["Traversal.FileModule"]
  defp archive_figure(lock, dir, manifest, {step, figure}, traces) do
    meta = %{
      journey: manifest.journey,
      locale: manifest.locale,
      run: manifest.run_id,
      step: step.name,
      figure: figure.name,
      highlight: figure.highlight,
      traces: traces
    }

    with {:ok, bytes} <- File.read(Path.join(dir, figure.file)), do: store(lock, bytes, meta)
  end

  # Applies `fun` to each item in order, collecting the results, until one fails.
  defp all_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  @doc """
  Stores one approved figure. `meta` names it: `:journey`, `:locale`, `:run`, `:step` and
  `:figure`, with its `:highlight` box (`%{x:, y:, width:, height:}` in the figure's
  pixels, or `nil`) and `:traces` (SHA-256 digests of the run's trace files). Everything
  else the run recorded comes from the lock. Returns the figure's `file_sha256`.
  """
  @impl AshJourneys.FigureStore
  def put(bytes, meta) when is_binary(bytes) and is_map(meta) do
    with {:ok, lock} <- Lock.read(root()), do: store(lock, bytes, meta)
  end

  @doc "The bytes of the figure whose `file_sha256` is `ref`."
  @impl AshJourneys.FigureStore
  def fetch(ref) when is_binary(ref) do
    case version(ref) do
      {:ok, %DocumentVersion{kind: @kind, bytes: bytes}} -> {:ok, bytes}
      {:ok, _none_or_other_kind} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  # -- storing ---------------------------------------------------------------------

  defp store(lock, bytes, meta) do
    key = "#{meta.step}.#{meta.figure}"

    with {:ok, entry} <- entry(lock, meta.journey, meta.locale),
         {:ok, figure} <- approved_figure(entry, key, meta.run),
         :ok <- hashes_to(bytes, figure.file_sha256),
         {:ok, traces} <- digests(Map.get(meta, :traces, [])) do
      config = config(lock, entry, meta, key, figure, traces)

      AshEvidence.repo().transaction(fn -> write!(bytes, figure, config, meta) end)
    end
  end

  # Inside the transaction: the version, then the execution's run and region, or nothing.
  defp write!(bytes, figure, config, meta) do
    with {:ok, version} <- ingest(bytes, figure.file_sha256),
         :ok <- execution(version, config, figure, Map.get(meta, :highlight)) do
      figure.file_sha256
    else
      {:error, error} -> AshEvidence.repo().rollback(error)
    end
  end

  defp entry(lock, id, locale) do
    case get_in(lock.journeys, [id, locale]) do
      nil -> refuse("the lock names no approved run of #{id} in #{locale}")
      entry -> {:ok, entry}
    end
  end

  defp approved_figure(entry, key, run) do
    cond do
      run != entry.run -> refuse("run #{run} is not the approved run (#{entry.run})")
      figure = entry.figures[key] -> {:ok, figure}
      true -> refuse("the approved run has no figure #{key}")
    end
  end

  defp hashes_to(bytes, expected) do
    case sha256(bytes) do
      ^expected -> :ok
      actual -> refuse("the bytes hash to #{actual}, but the lock approved #{expected}")
    end
  end

  defp digests(traces) when is_list(traces) do
    if Enum.all?(traces, &(is_binary(&1) and &1 =~ @digest)),
      do: {:ok, traces},
      else: refuse("trace digests must be lowercase hex SHA-256: #{inspect(traces)}")
  end

  defp digests(traces), do: refuse("trace digests must be a list: #{inspect(traces)}")

  defp refuse(reason), do: {:error, {:not_approved, reason}}

  defp config(lock, entry, meta, key, figure, traces) do
    %{
      "run" => entry.run,
      "commit" => entry.commit,
      "journey" => meta.journey,
      "version" => entry.version,
      "declaration_hash" => entry.hash,
      "locale" => meta.locale,
      "step" => meta.step,
      "figure" => meta.figure,
      "key" => key,
      "environment" => Atom.to_string(entry.environment),
      "browser" => %{"name" => lock.browser.name, "version" => lock.browser.version},
      "file" => figure.file,
      "file_sha256" => figure.file_sha256,
      "raster_sha256" => figure.raster_sha256,
      "width" => figure.width,
      "height" => figure.height,
      "highlight" => box_json(Map.get(meta, :highlight)),
      "trace_sha256" => traces
    }
  end

  defp box_json(nil), do: nil
  defp box_json(box), do: Map.new(box, fn {k, v} -> {to_string(k), v} end)

  # The evidence store addresses bytes by hash: bytes it already holds are reused.
  defp ingest(bytes, sha256) do
    case version(sha256) do
      {:ok, nil} -> AshEvidence.Domain.ingest_document(@kind, bytes, sha256)
      {:ok, %DocumentVersion{kind: @kind} = version} -> {:ok, version}
      {:ok, %DocumentVersion{kind: kind}} -> refuse("the bytes are already stored as #{kind}")
      {:error, error} -> {:error, error}
    end
  end

  defp version(sha256) do
    DocumentVersion
    |> Ash.Query.filter(sha256 == ^sha256 and is_nil(tenant))
    |> Ash.read_one()
  end

  # One closed run per execution of the figure; an execution already recorded is left.
  defp execution(version, config, figure, highlight) do
    with {:ok, runs} <- runs(version) do
      if Enum.any?(runs, &same_execution?(&1, config)),
        do: :ok,
        else: record(version, config, figure, highlight)
    end
  end

  defp same_execution?(run, config),
    do: run.config["run"] == config["run"] and run.config["key"] == config["key"]

  defp runs(version) do
    ParseRun
    |> Ash.Query.filter(document_version_id == ^version.id and instrument == @instrument)
    |> Ash.read()
  end

  defp record(version, config, figure, highlight) do
    with {:ok, run} <-
           AshEvidence.Domain.start_parse_run(version.id, @instrument, %{config: config}),
         :ok <- region(version, run, config["key"], figure, highlight),
         {:ok, _run} <- AshEvidence.Domain.mark_parse_run_ok(run) do
      :ok
    end
  end

  defp region(_version, _run, _key, _figure, nil), do: :ok

  defp region(version, run, key, figure, box) do
    w = figure.width * 1.0
    h = figure.height * 1.0

    geometry = %{
      page_w: w,
      page_h: h,
      unit: :px,
      rotation_applied: 0.0,
      bbox: %{
        x0: unit(box.x / w),
        y0: unit(box.y / h),
        x1: unit((box.x + box.width) / w),
        y1: unit((box.y + box.height) / h)
      }
    }

    with {:ok, _atom} <-
           AshEvidence.Domain.ingest_atom(version.id, run.id, 0, "#{key} highlight", :region, %{
             page: 1,
             geometry: geometry
           }) do
      :ok
    end
  end

  defp unit(value), do: value |> max(0.0) |> min(1.0)

  # -- the approved run --------------------------------------------------------------

  defp declared(id) do
    case Lock.declared() do
      {:ok, %{^id => journey}} -> {:ok, journey}
      {:ok, _declared} -> refuse("no configured module declares journey #{id}")
      {:error, problems} -> {:error, {:not_approved, Enum.join(problems, "; ")}}
    end
  end

  defp current(root, lock, id, journey, locale) do
    case Lock.verify(root, lock, id, journey, locale) do
      {:ok, entry, %Manifest{} = manifest} ->
        {:ok, entry, manifest}

      {:error, refusal, reasons} ->
        refuse("#{id} (#{locale}) is #{refusal}: #{Enum.join(reasons, ", ")}")
    end
  end

  # A trace file is read only to hash it. The paths are the operator's, who names the
  # trace files the run kept; nothing a request carries reaches here.
  @sobelow_skip ["Traversal.FileModule"]
  defp trace_digests(paths) do
    all_ok(paths, fn path ->
      case File.read(path) do
        {:ok, bytes} -> {:ok, sha256(bytes)}
        {:error, reason} -> {:error, {:trace, path, reason}}
      end
    end)
  end

  defp root, do: Application.app_dir(:ash_enterprise)

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
