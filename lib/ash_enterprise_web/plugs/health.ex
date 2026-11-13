defmodule AshEnterpriseWeb.Plugs.Health do
  @moduledoc """
  `GET /health` (and `HEAD`): is this node able to serve, for a load balancer, an uptime
  prober and the availability SLO (`devenv/observability/slo/`).

  Mounted in the endpoint ahead of the session and the router, so it needs no sign-in, sets
  no cookie and reads nothing a person owns. Every other request passes through untouched.

      {"status": "ok", "version": "0.1.0", "checks": {"repo": "ok", "oban": "ok"}}

  | Check | `ok` when |
  |---|---|
  | `repo` | the database answers `SELECT 1` within a second |
  | `oban` | the job runner's supervisor is running |

  200 when every check is `ok`, otherwise 503 with `"status": "unavailable"` and the
  failing check `"down"`. The body is only these fields: no tenant, no user, no count of
  anything, no error text, and never anything from the database beyond whether it answered.
  `cache-control: no-store`, so a proxy never answers for a node that has gone.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshEnterprise.Repo

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method, path_info: ["health"]} = conn, opts)
      when method in ["GET", "HEAD"] do
    # Read per request, not at init: the endpoint inits its plugs at compile time, and a
    # function cannot be compiled into it. A test passes its own `:checks`.
    checks = Keyword.get_lazy(opts, :checks, &checks/0)
    results = Map.new(checks, fn {name, check} -> {name, run(check)} end)
    healthy? = Enum.all?(results, fn {_name, result} -> result == "ok" end)

    body =
      Jason.encode!(%{
        status: if(healthy?, do: "ok", else: "unavailable"),
        version: version(),
        checks: results
      })

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(if(healthy?, do: 200, else: 503), body)
    |> halt()
  end

  def call(conn, _opts), do: conn

  @doc "The checks `/health` runs, as `{name, fun}`; each fun answers `:ok` or anything else."
  @spec checks() :: [{atom(), (-> term())}]
  def checks, do: [repo: &repo/0, oban: &oban/0]

  defp run(check) do
    case check.() do
      :ok -> "ok"
      _other -> "down"
    end
  rescue
    _exception -> "down"
  catch
    _kind, _reason -> "down"
  end

  # Raw SQL by design: a health probe is not a domain read (the ash-discipline exception for
  # health probes). It reads no table.
  defp repo do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", [], timeout: 1_000) do
      {:ok, _result} -> :ok
      error -> error
    end
  end

  defp oban do
    if is_pid(Oban.whereis(Oban)), do: :ok, else: :down
  end

  defp version do
    case Application.spec(:ash_enterprise, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
