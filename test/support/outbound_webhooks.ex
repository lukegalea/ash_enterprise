defmodule AshEnterprise.Test.OutboundWebhooks do
  @moduledoc """
  SYNTHETIC fixtures for the outbound webhook tests: a resolver that answers one public
  address, a `Req.Test` stub in place of the receiver, endpoints registered by a tenant's
  administrator, and teams created as the audited writes an endpoint subscribes to. Every
  host is under `example.test`; nothing leaves the test process.
  """

  alias AshEnterprise.Accounts.Team
  alias AshEnterprise.Integration
  alias AshEnterprise.Integration.Outbound.{Delivery, Egress, Endpoint, Transport}
  alias AshEnterprise.Platform.SystemActor

  @address {1, 1, 1, 1}

  @doc "The public address the test resolver answers."
  def address, do: @address

  @doc "Route the transport to a `Req.Test` stub and the guard to a fixed resolver; restore on exit."
  def stub_network!(resolver \\ fn _host -> {:ok, [@address]} end) do
    previous =
      {Application.get_env(:ash_enterprise, Transport),
       Application.get_env(:ash_enterprise, Egress)}

    Application.put_env(:ash_enterprise, Transport, req_options: [plug: {Req.Test, Transport}])
    Application.put_env(:ash_enterprise, Egress, resolver: resolver)

    ExUnit.Callbacks.on_exit(fn ->
      {transport, egress} = previous
      restore(Transport, transport)
      restore(Egress, egress)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:ash_enterprise, key)
  defp restore(key, value), do: Application.put_env(:ash_enterprise, key, value)

  @doc """
  A receiver stub answering `status`, that sends every request it gets to the test process as
  `{:received, %{body:, headers:, host:, path:}}`.
  """
  def receiver!(status \\ 204) do
    test_pid = self()

    Req.Test.stub(Transport, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:received,
         %{
           body: body,
           headers: Map.new(conn.req_headers),
           host: conn.host,
           path: conn.request_path,
           query: conn.query_string
         }}
      )

      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  @doc "An endpoint registered by `admin` for team creates (and `opts[:types]`)."
  def endpoint!(admin, opts \\ []) do
    Integration.register_webhook_endpoint!(
      %{
        url: Keyword.get(opts, :url, "https://hooks.example.test/in"),
        event_types: Keyword.get(opts, :types, ["ash_enterprise.team.create"])
      },
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  @doc "One audited team create in `admin`'s tenant."
  def team!(admin, name) do
    Team
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, owning_business_unit_id: admin.user.owning_business_unit_id},
      actor: SystemActor.seed(),
      tenant: admin.tenant
    )
    |> Ash.create!()
  end

  @doc "Run one endpoint's fan-out as the platform does, from `cursor` when given."
  def fan_out!(%Endpoint{} = endpoint, cursor \\ nil) do
    # A rewound cursor is the record as fan-out reads it, not a write: the change takes the
    # cursor from the record it is given.
    endpoint = if cursor, do: %{endpoint | cursor_sequence: cursor}, else: endpoint

    endpoint
    |> Ash.Changeset.for_update(:fan_out, %{},
      actor: SystemActor.oban(),
      tenant: endpoint.organization_id
    )
    |> Ash.update!()
  end

  @doc "The endpoint's deliveries, oldest event first."
  def deliveries(%Endpoint{} = endpoint) do
    require Ash.Query

    Delivery
    |> Ash.Query.filter(endpoint_id == ^endpoint.id)
    |> Ash.Query.sort(event_sequence: :asc)
    |> Ash.read!(tenant: endpoint.organization_id, authorize?: false)
  end

  @doc "Run one delivery attempt as the `:deliver` trigger does."
  def deliver!(%Delivery{} = delivery) do
    delivery
    |> Ash.Changeset.for_update(:deliver, %{},
      actor: SystemActor.oban(),
      tenant: delivery.organization_id
    )
    |> Ash.update!()
  end

  @doc "Reload an endpoint without authorization."
  def reload(%Endpoint{} = endpoint),
    do: Ash.get!(Endpoint, endpoint.id, tenant: endpoint.organization_id, authorize?: false)
end
