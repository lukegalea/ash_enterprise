defmodule AshBrowserTests.SandboxHookTest do
  # async: false: the telemetry handlers are global and are observed being attached.
  use ExUnit.Case, async: false

  alias AshBrowserTests.SandboxHook
  alias AshBrowserTests.TestKey
  alias Phoenix.Ecto.SQL.Sandbox, as: PhoenixSandbox

  @mount [:phoenix, :live_view, :mount, :start]
  @handle_event [:phoenix, :live_view, :handle_event, :start]
  @component_event [:phoenix, :live_component, :handle_event, :start]
  @endpoint [:phoenix, :endpoint, :start]
  @events [@mount, @handle_event, @component_event, @endpoint]

  defp handler?(event) do
    event |> :telemetry.list_handlers() |> Enum.any?(&(&1.id == {SandboxHook, :attached}))
  end

  defp all_attached?, do: Enum.all?(@events, &handler?/1)

  defp socket(connect_info, connected?) do
    transport = if connected?, do: self(), else: nil

    %Phoenix.LiveView.Socket{
      transport_pid: transport,
      private: %{connect_info: connect_info}
    }
  end

  setup do
    SandboxHook.attach()
    :ok
  end

  describe "tolerates anything without detaching" do
    defp bad_input(:nothing), do: %{}
    defp bad_input(:not_a_socket), do: %{socket: :nope}
    defp bad_input(:plain_map), do: %{socket: %{private: %{}}}
    defp bad_input(:no_connect_info), do: %{socket: live_socket(nil)}
    defp bad_input(:non_binary_agent), do: %{socket: live_socket(%{user_agent: 42})}
    defp bad_input(:real_browser), do: %{socket: live_socket(%{user_agent: "Mozilla/5.0 Chrome"})}

    defp bad_input(:malformed_metadata) do
      %{socket: live_socket(%{user_agent: "BeamMetadata (not_base64!!)"})}
    end

    defp bad_input(:not_metadata) do
      encoded = :garbage |> :erlang.term_to_binary() |> Base.url_encode64()
      %{socket: live_socket(%{user_agent: "BeamMetadata (#{encoded})"})}
    end

    defp bad_input(:endpoint_without_conn), do: %{conn: :nope}

    defp live_socket(connect_info) do
      private = if connect_info, do: %{connect_info: connect_info}, else: %{}
      %Phoenix.LiveView.Socket{private: private}
    end

    @inputs ~w(nothing not_a_socket plain_map no_connect_info non_binary_agent real_browser
               malformed_metadata not_metadata endpoint_without_conn)a

    for input <- @inputs, event <- @events do
      @input input
      @event event

      test "#{inspect(event)}: #{input}" do
        :telemetry.execute(@event, %{system_time: 1}, bad_input(@input))
        assert all_attached?()
      end
    end

    test "a stopped sandbox owner does not raise either" do
      owner = spawn(fn -> :ok end)
      ref = Process.monitor(owner)
      assert_receive {:DOWN, ^ref, :process, ^owner, _reason}

      user_agent =
        PhoenixSandbox.encode_metadata(%{
          repo: [AshBrowserTests.Fixture.Repo],
          owner: owner,
          trap_exit: false
        })

      :telemetry.execute(@mount, %{system_time: 1}, %{
        socket: socket(%{user_agent: user_agent}, true)
      })

      assert all_attached?()
    end
  end

  describe "with a sandboxed user agent" do
    test "sets the test key, allows the process and is idempotent" do
      owner = start_supervised!({Task, fn -> Process.sleep(:infinity) end})
      Ecto.Adapters.SQL.Sandbox.start_owner!(AshBrowserTests.Fixture.Repo, [])

      user_agent =
        PhoenixSandbox.encode_metadata(
          PhoenixSandbox.metadata_for([AshBrowserTests.Fixture.Repo], self())
        )

      assert TestKey.decode(user_agent).owner == self()
      refute TestKey.decode("not a sandboxed agent")
      refute TestKey.decode(nil)
      _unused = owner

      socket = socket(%{user_agent: user_agent}, false)
      :telemetry.execute(@mount, %{system_time: 1}, %{socket: socket})
      assert all_attached?()
      assert AshEnterprise.Telemetry.TestKey.current() == TestKey.from_owner(self())
    end

    test "attach/1 twice is fine" do
      assert :ok = SandboxHook.attach()
      assert :ok = SandboxHook.attach()
      assert all_attached?()
    end
  end
end
