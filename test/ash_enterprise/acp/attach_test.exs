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

  test "restore_default_handler/1 puts a replaced handler back" do
    {:ok, original} = before = :logger.get_handler_config(:default)

    on_exit(fn -> Attach.restore_default_handler(before) end)

    :ok = :logger.remove_handler(:default)
    assert {:error, _} = :logger.get_handler_config(:default)

    assert :ok = Attach.restore_default_handler(before)
    assert {:ok, ^original} = :logger.get_handler_config(:default)
  end
end
