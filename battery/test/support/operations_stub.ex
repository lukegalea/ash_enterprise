defmodule Battery.OperationsStub do
  @moduledoc """
  The battery registry's provider, as a `Req.Test` stub on `Battery.Operations.Transport`.

  `install!/1` makes the stub shared, because the inline engine and the executor may run
  outside the test process, and counts every request by `{method, path}`. It returns the
  accessor `count.(method, path)`; the path is the request path without its query, so a
  list and a read of one are counted apart.
  """

  alias Battery.Operations.Transport

  @doc "Install `fun` (a `Plug` function) as the provider. Returns `count.(method, path)`."
  @spec install!((Plug.Conn.t() -> Plug.Conn.t())) :: (String.t(), String.t() ->
                                                         non_neg_integer())
  def install!(fun) do
    # `mix platform_battery` runs the suite after `app.config` only; Req's ownership
    # server (which `Req.Test` needs) is started by its application.
    {:ok, _started} = Application.ensure_all_started(:req)
    Req.Test.set_req_test_to_shared()
    ExUnit.Callbacks.on_exit(fn -> Req.Test.set_req_test_to_private() end)

    {:ok, counts} = Agent.start_link(fn -> %{} end)

    Req.Test.stub(Transport, fn conn ->
      Agent.update(
        counts,
        &Map.update(&1, {conn.method, conn.request_path}, 1, fn n -> n + 1 end)
      )

      fun.(conn)
    end)

    fn method, path -> Agent.get(counts, &Map.get(&1, {method, path}, 0)) end
  end

  @doc "Answer `status` with a JSON `body`."
  def json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
