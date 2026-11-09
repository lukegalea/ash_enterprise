defmodule AshEnterprise.Telemetry.Correlation do
  @moduledoc """
  A server-minted correlation id for one user action, carried in the process
  dictionary and stamped on every span, job and log it produces.

  It is the join between signals that a trace cannot connect by itself: a
  background job starts a new trace linked to the request, so the id is what says
  "these belong to the same action". Audit rows use the same id.

  **The server always mints it.** A browser can supply a parent span through a
  validated `traceparent` and nothing else. `AshEnterprise.Telemetry.BrowserContext`
  starts a new id for every LiveView mount and event; no code path reads an id
  from client input.

  ## Using your own implementation

  A host that already has a correlation module implements these callbacks and
  passes `correlation: MyApp.Correlation` to `AshEnterprise.Telemetry.setup/1`.
  This module is the default implementation.

  `clear/0` is optional: it lets the package drop an id when an event ends. Without
  it the previous id stays current until the next event replaces it.
  """

  @key {__MODULE__, :id}

  @callback current() :: String.t() | nil
  @callback put(String.t()) :: term()
  @callback start_new() :: String.t()
  @callback with_correlation(String.t(), (-> result)) :: result when result: var
  @callback clear() :: term()
  @optional_callbacks clear: 0

  @behaviour __MODULE__

  @doc "The current id, or nil. Never generates one."
  @impl true
  @spec current() :: String.t() | nil
  def current, do: Process.get(@key)

  @doc "Sets the current id, for restoring one carried across a process boundary."
  @impl true
  @spec put(String.t()) :: String.t() | nil
  def put(id) when is_binary(id), do: Process.put(@key, id)

  @doc "Mints a new id and makes it current."
  @impl true
  @spec start_new() :: String.t()
  def start_new do
    id = Ecto.UUID.generate()
    Process.put(@key, id)
    id
  end

  @doc """
  Runs `fun` under `id`, then restores whatever was current before, even if `fun`
  raises.
  """
  @impl true
  @spec with_correlation(String.t(), (-> result)) :: result when result: var
  def with_correlation(id, fun) when is_binary(id) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, id)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc "Forgets the current id."
  @impl true
  @spec clear() :: term()
  def clear, do: Process.delete(@key)
end
