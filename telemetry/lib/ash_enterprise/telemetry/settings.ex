defmodule AshEnterprise.Telemetry.Settings do
  @moduledoc false

  # What `AshEnterprise.Telemetry.setup/1` was told, in :persistent_term because
  # span processors and telemetry handlers read it on every span. Everything
  # falls back to a default so that a span started before setup is merely
  # undecorated, never a crash.

  @key {__MODULE__, :settings}

  @defaults %{
    correlation: AshEnterprise.Telemetry.Correlation,
    event_attributes: nil,
    browser_context?: false,
    dropped_paths: ["/otel/v1/traces"]
  }

  @spec put(map()) :: :ok
  def put(settings) when is_map(settings) do
    :persistent_term.put(@key, Map.merge(@defaults, settings))
  end

  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  @spec correlation() :: module()
  def correlation, do: get(:correlation)

  @spec event_attributes() :: mfa() | (String.t(), map(), term() -> map()) | nil
  def event_attributes, do: get(:event_attributes)

  @spec browser_context?() :: boolean()
  def browser_context?, do: get(:browser_context?)

  @spec dropped_paths() :: [String.t()]
  def dropped_paths, do: get(:dropped_paths)

  defp get(key) do
    @key
    |> :persistent_term.get(@defaults)
    |> Map.get(key)
  end
end
