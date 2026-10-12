defmodule AshEnterprise.Acp.AttachTest do
  @moduledoc """
  `scripts/acp-attach` runs `AshEnterprise.Acp.Attach.serve/1` inside a live
  server. The wire must round-trip through its forwarding device, and the
  server's own `:default` logger handler must survive the stdio endpoint's
  handler replacement.
  """

  # The logger handler is node-global.
  use ExUnit.Case, async: false

  alias AshEnterprise.Acp.Attach

  defmodule LoudStore do
    @moduledoc false
    # A session store that writes through its group leader, as a logger
    # handler does on the logging process's behalf.
    def create(_init) do
      IO.write("not the wire\n")
      {:ok, %AshEnterprise.Acp.Session{session_id: "s-1"}}
    end
  end

  @session_new ~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}\n)
  @initialize ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}\n)

  test "the wire round-trips and the default logger handler is left as it was" do
    before = :logger.get_handler_config(:default)
    {:ok, wire} = StringIO.open(@initialize)

    assert :ok = Attach.serve(device: wire)

    {_input, output} = StringIO.contents(wire)
    [line] = String.split(output, "\n", trim: true)
    assert %{"id" => 1, "result" => %{"protocolVersion" => 1}} = Jason.decode!(line)

    assert :logger.get_handler_config(:default) == before
  end

  test "output a session writes through its group leader stays off the wire" do
    {:ok, wire} = StringIO.open(@initialize <> @session_new)
    {:ok, local_io} = StringIO.open("")
    leader = Process.group_leader()

    assert :ok =
             Attach.serve(
               device: wire,
               group_leader: local_io,
               config: AshAcp.config(session_store: LoudStore)
             )

    {_input, output} = StringIO.contents(wire)
    lines = String.split(output, "\n", trim: true)

    assert [%{"id" => 1}, %{"id" => 2, "result" => %{"sessionId" => "s-1"}}] =
             Enum.map(lines, &Jason.decode!/1)

    assert {_, "not the wire\n"} = StringIO.contents(local_io)
    assert Process.group_leader() == leader
  end

  test "restore_default_handler/1 puts a replaced handler back" do
    {:ok, original} = before = :logger.get_handler_config(:default)

    on_exit(fn -> Attach.restore_default_handler(before) end)

    :ok = :logger.remove_handler(:default)
    assert {:error, _} = :logger.get_handler_config(:default)

    assert :ok = Attach.restore_default_handler(before)
    assert {:ok, ^original} = :logger.get_handler_config(:default)
  end
end
