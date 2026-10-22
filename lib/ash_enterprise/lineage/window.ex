defmodule AshEnterprise.Lineage.Window do
  @moduledoc """
  The time windows the Lineage app draws its graph over: the last hour, 24
  hours, 7 days or 14 days (the retention window,
  `AshEnterprise.Lineage.Retention`).

  A fixed list, not a table: it is a resource only so the Lineage surface can
  offer it as a context picker beside the job picker, and the diagram source
  reads the selection the same way it reads the job's. Readable by anyone who
  can open the surface; it holds no data.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Lineage,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    lineage?: false,
    policies?: false

  @windows [
    %{id: "hour", label: "Last hour", hours: 1},
    %{id: "day", label: "Last 24 hours", hours: 24},
    %{id: "week", label: "Last 7 days", hours: 7 * 24},
    %{id: "fortnight", label: "Last 14 days", hours: 14 * 24}
  ]

  @default "day"

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :label, :string, allow_nil?: false, public?: true
    attribute :hours, :integer, allow_nil?: false, public?: true
  end

  actions do
    read :read do
      primary? true
      prepare AshEnterprise.Lineage.Preparations.Windows
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end
  end

  @doc "The windows, as records."
  @spec all() :: [t()]
  def all, do: Enum.map(@windows, &struct(__MODULE__, &1))

  @doc "The window with id `id`, or the default (the last 24 hours)."
  @spec fetch(String.t() | nil) :: t()
  def fetch(id), do: Enum.find(all(), &(&1.id == id)) || fetch(@default)

  @doc "The start of window `id` (or of the default), counted back from `now`."
  @spec since(String.t() | nil, DateTime.t()) :: DateTime.t()
  def since(id, now \\ DateTime.utc_now()),
    do: DateTime.add(now, -fetch(id).hours * 3600, :second)

  @type t :: %__MODULE__{}
end
