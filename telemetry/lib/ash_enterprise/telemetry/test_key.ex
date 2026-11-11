defmodule AshEnterprise.Telemetry.TestKey do
  @moduledoc """
  The per-test key, for selecting one test's spans out of the global pipeline.

  The OpenTelemetry pipeline is global, so a test never asserts on "the last trace"
  or clears the sink: it sets a key and selects by it
  (`AshEnterprise.Telemetry.TraceSink.by_test_key/1`).
  """

  @key {__MODULE__, :key}

  @doc "Stamps `key` on every span this process starts from now on."
  @spec put(String.t()) :: term()
  def put(key) when is_binary(key), do: Process.put(@key, key)

  @spec current() :: String.t() | nil
  def current, do: Process.get(@key)

  @spec clear() :: term()
  def clear, do: Process.delete(@key)
end
