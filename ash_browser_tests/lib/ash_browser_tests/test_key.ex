defmodule AshBrowserTests.TestKey do
  @moduledoc """
  The per-test key that selects one test's spans out of the global OpenTelemetry
  pipeline.

  The key is the sandbox owner of the test, which the browser carries in its user
  agent (`Phoenix.Ecto.SQL.Sandbox.encode_metadata/1`). A server process learns its
  test from that one header, and stamps the key on every span it starts.
  """

  # AshEnterprise.Telemetry.TestKey is resolved at runtime: a host that takes this
  # package without the telemetry package still gets browser tests, without keys.
  @compile {:no_warn_undefined, AshEnterprise.Telemetry.TestKey}

  @attribute "ash.test_key"

  @doc "The span attribute carrying the key."
  @spec attribute() :: String.t()
  def attribute, do: @attribute

  @doc "The key for a sandbox owner."
  @spec from_owner(pid()) :: String.t()
  def from_owner(owner) when is_pid(owner), do: inspect(owner)

  @doc """
  The sandbox metadata in a user agent, or `nil` when the header is absent,
  belongs to a real browser, or is malformed. Never raises.
  """
  @spec decode(term()) :: map() | nil
  def decode(user_agent) when is_binary(user_agent) do
    case Phoenix.Ecto.SQL.Sandbox.decode_metadata(user_agent) do
      %{owner: owner} = metadata when is_pid(owner) -> metadata
      _other -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  def decode(_user_agent), do: nil

  @doc "Stamps `key` on every span this process starts from now on."
  @spec put(String.t()) :: :ok
  def put(key) when is_binary(key) do
    if Code.ensure_loaded?(AshEnterprise.Telemetry.TestKey) do
      AshEnterprise.Telemetry.TestKey.put(key)
    end

    :ok
  end
end
