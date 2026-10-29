defmodule AshEnterprise.Test.Execution.FakeBoard do
  @moduledoc """
  The outside specialist board `AshEnterprise.Test.Execution.ReferralBoard` refers to,
  as a `Req.Test` plug behind the Nango façade. It keeps what it accepted in an ETS table
  the test owns, so a test counts the calls that reached it and the referrals it holds,
  from any process.

  `mode/1` sets how it answers referrals:

    * `:accept`: it takes the referral (`201`);
    * `:lose_ack`: it takes the referral and the answer is a `502`: the effect happened
      and the caller cannot tell;
    * `:busy`: `429` with `Retry-After: 60`, nothing taken (longer than the Nango
      façade waits, so it answers `:rate_limited` at once);
    * `:reject`: `400`, nothing taken.

  A referral sent with an `Idempotency-Key` it has seen is not taken again. A lookup
  (`GET /referrals?reference=…`) answers `200` with the referral or `404`.
  """

  import Plug.Conn

  alias AshEnterprise.Integration.Nango.Proxy

  @table :execution_fake_board

  @doc """
  A fresh board answering `:accept`, the Nango façade pointed at it for every process,
  and a Nango secret for the test.
  """
  def start! do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])
    mode(:accept)

    previous = System.get_env("NANGO_SECRET_KEY")
    System.put_env("NANGO_SECRET_KEY", "nango-test-secret-not-a-real-key")

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: System.put_env("NANGO_SECRET_KEY", previous),
        else: System.delete_env("NANGO_SECRET_KEY")
    end)

    Req.Test.set_req_test_to_shared()
    Req.Test.stub(Proxy, &__MODULE__.call/1)
    :ok
  end

  @doc "How the board answers referrals from now on."
  def mode(mode), do: :ets.insert(@table, {:mode, mode})

  @doc "How many referral calls reached the board."
  def calls, do: :ets.lookup_element(@table, :calls, 2, 0)

  @doc "How many referrals the board holds."
  def referrals, do: :ets.select_count(@table, [{{{:referral, :_}, :_}, [], [true]}])

  @doc false
  def call(%Plug.Conn{method: "POST", request_path: "/proxy/referrals"} = conn) do
    :ets.update_counter(@table, :calls, 1, {:calls, 0})
    {:ok, raw, conn} = read_body(conn)
    %{"reference" => reference} = Jason.decode!(raw)

    case :ets.lookup_element(@table, :mode, 2) do
      :busy -> conn |> put_resp_header("retry-after", "60") |> json(429, %{"error" => "busy"})
      :reject -> json(conn, 400, %{"error" => "bad referral"})
      mode -> accept(conn, reference, mode)
    end
  end

  def call(%Plug.Conn{method: "GET", request_path: "/proxy/referrals"} = conn) do
    conn = fetch_query_params(conn)

    case :ets.match(@table, {{:referral, :"$1"}, conn.query_params["reference"]}) do
      [[id] | _] -> json(conn, 200, %{"id" => id})
      [] -> json(conn, 404, %{"error" => "no such referral"})
    end
  end

  defp accept(conn, reference, mode) do
    id =
      case get_req_header(conn, "idempotency-key") do
        [key] -> "ref-" <> key
        [] -> "ref-" <> Integer.to_string(System.unique_integer([:positive]))
      end

    :ets.insert_new(@table, {{:referral, id}, reference})

    if mode == :lose_ack,
      do: json(conn, 502, %{"error" => "upstream timed out"}),
      else: json(conn, 201, %{"id" => id})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
