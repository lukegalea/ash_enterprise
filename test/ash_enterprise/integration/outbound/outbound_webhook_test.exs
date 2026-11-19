defmodule AshEnterprise.Integration.Outbound.OutboundWebhookTest do
  @moduledoc """
  An audited write becomes a signed CloudEvent at a tenant's endpoint: fan-out from the
  tenant's audit log, the disclosure gate, the retry schedule, dead letters and auto-disable,
  the payload's shape and the Standard Webhooks signature. The receiver is a `Req.Test` stub
  and the resolver answers one public address, so nothing leaves the test process.
  """

  # async: false: the transport's and the egress guard's application env are node-global.
  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]
  import AshEnterprise.Test.OutboundWebhooks

  alias AshEnterprise.Integration
  alias AshEnterprise.Integration.Outbound.{Changes, Delivery, Endpoint, Transport}

  setup do
    stub_network!()
    %{admin: tenant!()}
  end

  test "events before the endpoint existed are never delivered", %{admin: admin} do
    receiver!()
    team!(admin, "Before")
    endpoint = endpoint!(admin)

    fan_out!(endpoint)
    assert deliveries(endpoint) == []

    after_team = team!(admin, "After")
    fan_out!(reload(endpoint))

    assert [%Delivery{subject_id: subject, event_type: "ash_enterprise.team.create"}] =
             deliveries(endpoint)

    assert subject == after_team.id
  end

  test "a disclosure-gate refusal sends nothing and records the delivery refused", %{admin: admin} do
    receiver!()
    endpoint = endpoint!(admin)
    team!(admin, "Owed")
    fan_out!(endpoint)
    [delivery] = deliveries(endpoint)

    # Disabled between the fan-out and the send: the gate refuses, and nothing goes out.
    {:ok, _} =
      Integration.disable_webhook_endpoint(reload(endpoint),
        actor: admin.actor,
        tenant: admin.tenant
      )

    assert %Delivery{state: :refused, last_reason: "endpoint_inactive", attempts: 1} =
             deliver!(delivery)

    refute_received {:received, _}
  end

  test "an egress refusal sends nothing, refuses the delivery and marks the endpoint failing", %{
    admin: admin
  } do
    receiver!()
    stub_network!(fn _host -> {:ok, [{1, 1, 1, 1}, {169, 254, 169, 254}]} end)
    endpoint = endpoint!(admin)
    team!(admin, "Owed")
    fan_out!(endpoint)
    [delivery] = deliveries(endpoint)

    assert %Delivery{state: :refused, last_reason: "egress_private_address"} = deliver!(delivery)
    refute_received {:received, _}

    assert %Endpoint{status: :failing, status_reason: "egress_private_address"} = reload(endpoint)
  end

  test "a 5xx is retried later with the same webhook-id", %{admin: admin} do
    receiver!(503)
    endpoint = endpoint!(admin)
    team!(admin, "Retried")
    fan_out!(endpoint)
    [delivery] = deliveries(endpoint)

    before = DateTime.utc_now()
    retried = deliver!(delivery)

    assert %Delivery{state: :pending, attempts: 1, last_status: 503, last_reason: "server_error"} =
             retried

    # The next attempt waits the first step of the schedule, a minute.
    assert DateTime.diff(retried.next_attempt_at, before, :second) in 59..61
    assert_received {:received, %{headers: %{"webhook-id" => first_id}}}

    receiver!(200)
    assert %Delivery{state: :delivered, attempts: 2, last_reason: nil} = deliver!(retried)
    assert_received {:received, %{headers: %{"webhook-id" => ^first_id}}}
    assert first_id == delivery.event_id
  end

  test "after the last attempt the delivery is dead and repeated deaths disable the endpoint", %{
    admin: admin
  } do
    receiver!(500)
    endpoint = endpoint!(admin)
    for n <- 1..Changes.NoteOutcome.dead_limit(), do: team!(admin, "Doomed #{n}")
    fan_out!(endpoint)
    owed = deliveries(endpoint)
    assert length(owed) == Changes.NoteOutcome.dead_limit()

    [first | rest] = owed

    dead =
      Enum.reduce(1..Changes.Deliver.max_attempts(), first, fn _attempt, delivery ->
        deliver!(delivery)
      end)

    assert %Delivery{state: :dead, attempts: 6, last_status: 500} = dead
    assert %Endpoint{status: :active, consecutive_dead: 1} = reload(endpoint)

    for delivery <- rest do
      Enum.reduce(1..Changes.Deliver.max_attempts(), delivery, fn _, d -> deliver!(d) end)
    end

    assert %Endpoint{
             status: :failing,
             status_reason: "repeated_dead_letters",
             consecutive_dead: 3
           } =
             reload(endpoint)

    # A person turns it back on, and the run of dead letters starts again.
    {:ok, enabled} =
      Integration.enable_webhook_endpoint(reload(endpoint),
        actor: admin.actor,
        tenant: admin.tenant
      )

    assert %Endpoint{status: :active, consecutive_dead: 0, status_reason: nil} = enabled
  end

  test "the body is a CloudEvents 1.0 structured event carrying no record attributes", %{
    admin: admin
  } do
    receiver!()
    endpoint = endpoint!(admin, url: "https://hooks.example.test/in/tenant-a?route=1")
    team = team!(admin, "Confidential team name")
    fan_out!(endpoint)
    [delivery] = deliveries(endpoint)

    assert %Delivery{state: :delivered} = deliver!(delivery)
    assert_received {:received, request}

    # Sent to the vetted address, at the registered path and query.
    assert request.host == "1.1.1.1"
    assert request.path == "/in/tenant-a"
    assert request.query == "route=1"
    assert request.headers["content-type"] == "application/cloudevents+json"

    event = Jason.decode!(request.body)

    assert Map.keys(event) |> Enum.sort() ==
             ~w(data datacontenttype id source specversion subject time type)

    assert event["specversion"] == "1.0"
    assert event["id"] == delivery.event_id
    assert event["type"] == "ash_enterprise.team.create"
    assert event["source"] == "/organizations/#{admin.tenant}"
    assert event["subject"] == team.id
    assert event["datacontenttype"] == "application/json"
    assert event["data"] == %{"id" => team.id}
    assert {:ok, _, _} = DateTime.from_iso8601(event["time"])
    refute request.body =~ "Confidential"
  end

  test "the Standard Webhooks signature verifies over id.timestamp.body", %{admin: admin} do
    receiver!()
    endpoint = endpoint!(admin)
    "whsec_" <> key = endpoint.__metadata__.signing_secret
    team!(admin, "Signed")
    fan_out!(endpoint)
    [delivery] = deliveries(endpoint)
    deliver!(delivery)

    assert_received {:received, %{body: body, headers: headers}}

    id = headers["webhook-id"]
    timestamp = headers["webhook-timestamp"]
    assert "v1," <> signature = headers["webhook-signature"]

    expected =
      :crypto.mac(:hmac, :sha256, Base.decode64!(key), "#{id}.#{timestamp}.#{body}")
      |> Base.encode64()

    assert signature == expected
    assert abs(String.to_integer(timestamp) - System.os_time(:second)) < 30

    # One altered byte and it no longer verifies.
    refute Transport.signature("whsec_" <> key, id, timestamp, body <> " ") == signature
  end

  test "a redelivery of the same event does not create a second delivery row", %{admin: admin} do
    receiver!()
    endpoint = endpoint!(admin)
    start = endpoint.cursor_sequence
    team!(admin, "Once")

    fan_out!(endpoint)
    [delivery] = deliveries(endpoint)

    # The same events fanned out again, from the old cursor: the identity holds.
    fan_out!(reload(endpoint), start)
    assert [%Delivery{id: id}] = deliveries(endpoint)
    assert id == delivery.id

    # A person's redeliver sends the same row again, from the first attempt.
    delivered = deliver!(delivery)

    {:ok, again} =
      Integration.redeliver_webhook(delivered, actor: admin.actor, tenant: admin.tenant)

    assert %Delivery{state: :pending, attempts: 0} = again
    assert %Delivery{state: :delivered, attempts: 1} = deliver!(again)
    assert [%Delivery{id: ^id}] = deliveries(endpoint)

    assert_received {:received, %{headers: %{"webhook-id" => first}}}
    assert_received {:received, %{headers: %{"webhook-id" => ^first}}}
  end

  test "a full page of events the endpoint does not subscribe to does not skip the rest", %{
    admin: admin
  } do
    previous = Application.get_env(:ash_enterprise, Changes.FanOut)
    Application.put_env(:ash_enterprise, Changes.FanOut, page: 2)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_enterprise, Changes.FanOut, previous),
        else: Application.delete_env(:ash_enterprise, Changes.FanOut)
    end)

    endpoint = endpoint!(admin)
    first = team!(admin, "First")

    # Two updates the endpoint is not subscribed to fill the first page with one match.
    Enum.reduce(["First, renamed", "First, renamed again"], first, fn name, team ->
      team
      |> Ash.Changeset.for_update(:update, %{name: name},
        actor: AshEnterprise.Platform.SystemActor.seed(),
        tenant: admin.tenant
      )
      |> Ash.update!()
    end)

    second = team!(admin, "Second")

    high_water = AshEnterprise.Audit.EventSource.latest_sequence(admin.tenant)

    Enum.reduce_while(1..10, endpoint, fn _, endpoint ->
      endpoint = fan_out!(endpoint)
      if endpoint.cursor_sequence >= high_water, do: {:halt, endpoint}, else: {:cont, endpoint}
    end)

    assert endpoint |> deliveries() |> Enum.map(& &1.subject_id) == [first.id, second.id]
  end

  test "the scheduled fan-out and the deliver trigger send an event through Oban", %{admin: admin} do
    receiver!()
    endpoint = endpoint!(admin)
    team = team!(admin, "Through Oban")

    AshOban.Test.schedule_and_run_triggers({Endpoint, :fan_out}, drain_queues?: true)
    assert [%Delivery{state: :pending}] = deliveries(endpoint)

    AshOban.Test.schedule_and_run_triggers({Delivery, :deliver}, drain_queues?: true)
    assert [%Delivery{state: :delivered, attempts: 1}] = deliveries(endpoint)

    assert_received {:received, %{body: body}}
    assert %{"subject" => subject} = Jason.decode!(body)
    assert subject == team.id
  end

  test "an endpoint subscribed to other types receives nothing for a team create", %{admin: admin} do
    receiver!()
    endpoint = endpoint!(admin, types: ["ash_enterprise.team.destroy"])
    team!(admin, "Not subscribed")
    fan_out!(endpoint)

    assert deliveries(endpoint) == []
    assert reload(endpoint).cursor_sequence > endpoint.cursor_sequence
  end
end
