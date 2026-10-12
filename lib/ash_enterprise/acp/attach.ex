defmodule AshEnterprise.Acp.Attach do
  @moduledoc """
  ACP into an **already-running** node, over Erlang distribution.

  `mix ash_acp.stdio` boots a second copy of the application: a second
  endpoint, a second Oban running the same cron syncs, and a fight over the
  `_build` lock with the server that is already up. `bin/acp-attach` avoids
  all of that: it starts a tiny hidden node, connects to the running one and
  calls `serve/1` there with `:erpc`. The remote call inherits the caller's
  group leader, so the ACP wire is the bridge's own stdin/stdout while every
  action runs inside the live application, under its policies, as
  `AshEnterprise.Acp.system_actor/0`.

  ## The logger

  `AshAcp.run_stdio/1` replaces the node's `:default` logger handler before
  its loop starts, because on a stdio node that handler shares stdout with
  the wire. Here the wire is the bridge's group leader, not this node's
  stdout, so the replacement only damages the running server's own log (and
  with the pinned ash_acp the replacement handler is rejected as invalid, so
  the node is left with no default handler at all). `serve/1` snapshots the
  handler and puts it back on the first wire I/O request, which strictly
  follows the replacement.
  """

  @doc """
  Serves one ACP connection whose wire is the calling process's group leader
  (or `opts[:device]`), until EOF.

  For the connection's lifetime the calling process's group leader is moved
  to `opts[:group_leader]` (default: this node's `:user`, i.e. the server's
  own stdout). The default logger handler writes through the *logging*
  process's group leader, so without the move every log line a session emits
  (Ecto's SQL debug included) would travel back over distribution onto the
  wire. The wire itself is handed to the endpoint explicitly as its device.
  Other options pass through to `AshAcp.run_stdio/1`.
  """
  @spec serve(keyword()) :: :ok
  def serve(opts \\ []) do
    {wire, opts} = Keyword.pop(opts, :device)
    wire = wire || Process.group_leader()
    {local_io, opts} = Keyword.pop_lazy(opts, :group_leader, fn -> Process.whereis(:user) end)
    previous_leader = Process.group_leader()
    handler = :logger.get_handler_config(:default)
    owner = self()
    device = spawn(fn -> start_proxy(owner, wire, handler) end)

    if is_pid(local_io), do: Process.group_leader(self(), local_io)

    try do
      AshAcp.run_stdio(Keyword.put(opts, :device, device))
    after
      send(device, :stop)
      Process.group_leader(self(), previous_leader)
    end
  end

  # An I/O server that forwards every request, unchanged, to the real wire.
  # Replies go straight from the wire to the original requester, so the
  # proxy never sits on the reply path.
  defp start_proxy(owner, wire, handler) do
    owner_ref = Process.monitor(owner)
    wire_ref = Process.monitor(wire)
    await_first_request(wire, handler, owner_ref, wire_ref)
  end

  defp await_first_request(wire, handler, owner_ref, wire_ref) do
    receive do
      {:io_request, _from, _reply_as, _request} = request ->
        restore_default_handler(handler)
        send(wire, request)
        forward(wire, owner_ref, wire_ref)

      :stop ->
        restore_default_handler(handler)

      {:DOWN, ref, :process, _, _} when ref in [owner_ref, wire_ref] ->
        restore_default_handler(handler)
    end
  end

  defp forward(wire, owner_ref, wire_ref) do
    receive do
      {:io_request, _from, _reply_as, _request} = request ->
        send(wire, request)
        forward(wire, owner_ref, wire_ref)

      :stop ->
        :ok

      # The bridge went away: exiting fails the reader's pending request
      # (io monitors its server), which ends the endpoint loop as EOF.
      {:DOWN, ref, :process, _, _} when ref in [owner_ref, wire_ref] ->
        :ok
    end
  end

  @doc false
  def restore_default_handler({:ok, %{module: module} = config}) do
    if :logger.get_handler_config(:default) != {:ok, config} do
      _ = :logger.remove_handler(:default)
      :logger.add_handler(:default, module, Map.drop(config, [:id, :module]))
    else
      :ok
    end
  end

  def restore_default_handler({:error, _not_found}) do
    _ = :logger.remove_handler(:default)
    :ok
  end
end
