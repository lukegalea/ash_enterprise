defmodule AshEnterprise.Zones do
  @moduledoc """
  Declared safe zones and the admission rule of
  [ADR 0042](../../docs/adr/0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md).

  A zone is a declared boundary with a jurisdiction, a classification ceiling
  and the residency restrictions it cannot satisfy (`AshEnterprise.Zones.Zone`).
  Data may be written into a store in a zone only if its own tags are admissible
  there (`AshEnterprise.Zones.Admission`). The check runs on the ingest path —
  add `AshEnterprise.Zones.Changes.Admit` to the create action that first writes
  the data — and deliberately not in a policy check, which must never query or
  read files.

  ## Where declarations come from

  Declarations are JSON files, one zone per file, listed in config:

      config :ash_enterprise, AshEnterprise.Zones,
        declarations: [
          "/etc/zones/my-zone.json",
          {:priv, "zones/examples/ontario.json"}
        ]

  A `{:priv, path}` entry resolves inside this application's `priv` directory.
  **Nothing is configured by default**, so every admission fails closed with
  `AshEnterprise.Zones.Errors.UndeclaredZone` until a deployment declares a zone.
  This repository ships one example declaration and no real one: a real zone's
  members, stores and controls describe somebody's infrastructure and belong
  with that deployment, not in a public template.

  Files are read on every lookup rather than cached. There are a handful of them
  and they are small, and it means an edit — narrowing a zone, or withdrawing
  one — takes effect on the next write rather than the next restart.
  """

  alias AshEnterprise.Zones.{Admission, Zone}
  alias AshEnterprise.Zones.Errors.{Inadmissible, UndeclaredZone}

  @doc "The configured declaration sources."
  @spec declaration_sources() :: [String.t() | {:priv, String.t()}]
  def declaration_sources do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:declarations, [])
  end

  @doc """
  All configured zones. Raises if any declaration is unreadable or invalid, or
  if two declare the same id: a broken declaration is a configuration error, not
  something to skip past quietly.
  """
  @spec all() :: [Zone.t()]
  def all do
    zones = Enum.map(declaration_sources(), &load!/1)

    case zones |> Enum.frequencies_by(& &1.id) |> Enum.filter(fn {_, n} -> n > 1 end) do
      [] ->
        zones

      dupes ->
        raise ArgumentError,
              "zone ids declared more than once: #{inspect(Enum.map(dupes, &elem(&1, 0)))}"
    end
  end

  @doc "The zone declared with `id`."
  @spec fetch(String.t()) :: {:ok, Zone.t()} | {:error, UndeclaredZone.t()}
  def fetch(id) when is_binary(id) do
    case Enum.find(all(), &(&1.id == id)) do
      nil -> {:error, UndeclaredZone.exception(zone: id)}
      zone -> {:ok, zone}
    end
  end

  def fetch(nil), do: {:error, UndeclaredZone.exception(zone: nil)}

  @doc "Loads and validates one declaration file."
  @spec load(String.t() | {:priv, String.t()}) :: {:ok, Zone.t()} | {:error, String.t()}
  def load(source) do
    path = resolve(source)

    with {:ok, body} <- read(path),
         {:ok, decoded} <- decode(path, body) do
      case Zone.from_map(decoded) do
        {:ok, zone} -> {:ok, zone}
        {:error, problems} -> {:error, "#{path}: " <> Enum.join(problems, "; ")}
      end
    end
  end

  @doc "As `load/1`, raising on an unreadable or invalid declaration."
  @spec load!(String.t() | {:priv, String.t()}) :: Zone.t()
  def load!(source) do
    case load(source) do
      {:ok, zone} -> zone
      {:error, message} -> raise ArgumentError, "invalid zone declaration: " <> message
    end
  end

  @doc """
  Whether data carrying `tags` may enter `zone` today.

  `zone` is a `Zone` or a zone id. `tags` is `%{data_class: ..., residency: ...}`,
  either of which may be `nil` (untagged, and therefore refused). Returns `:ok`,
  or an error naming the zone and the reason, never the data.

  Options: `:on` — the date to check the declaration's `review_by` against
  (default: today, UTC); `:field` — the field to attach a refusal to.
  """
  @spec admit(Zone.t() | String.t() | nil, Admission.tags(), keyword()) ::
          :ok | {:error, Inadmissible.t() | UndeclaredZone.t()}
  def admit(zone, tags, opts \\ [])

  def admit(%Zone{} = zone, tags, opts) do
    on = Keyword.get_lazy(opts, :on, &Date.utc_today/0)

    case Admission.check(zone, tags, on: on) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Inadmissible.exception(zone: zone.id, reason: reason, field: opts[:field])}
    end
  end

  def admit(id, tags, opts) do
    with {:ok, zone} <- fetch(id), do: admit(zone, tags, opts)
  end

  defp resolve({:priv, relative}),
    do: Application.app_dir(:ash_enterprise, Path.join("priv", relative))

  defp resolve(path) when is_binary(path), do: path

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "#{path}: cannot read (#{:file.format_error(reason)})"}
    end
  end

  defp decode(path, body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, "#{path}: not valid JSON (#{Exception.message(error)})"}
    end
  end
end
