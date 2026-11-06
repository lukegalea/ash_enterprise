defmodule Battery.Integration.OperationsWebhookProcessTest do
  @moduledoc """
  Operations — provider webhook ↔ process receive task.

  The seam: ash_operations' webhook ingress and provider contract (the exact signed bytes,
  a redelivery-stable dedup key, ids only) meet an ash_bpmn receive task correlated on an
  envelope.

  A process holds a submission whose activation id it read off the subject, and parks at a
  receive task for the envelope `Battery.Operations.ActivationSettled` carries for that id.
  The provider's webhook is signed and posted through `Battery.Operations.Router`, with no
  body parser before the ingress. It records a `Delivery` (the id and nothing else). A
  follow-up reads the provider by that id through a declared operation and writes the
  envelope from THE READ, which the engine's correlator wakes the process with.

  Asserted: the token parks listening for this activation id; a signed delivery is
  accepted (204, `:enqueued`) and makes one `Delivery` and no provider request; the
  follow-up makes exactly one read and one envelope, and the process completes; the nudge
  is not a fact (the webhook says `revoked`, the read says `active`, and the process takes
  the `active` branch); a redelivery is `:duplicate` and moves nothing; a bad or stale
  signature is 401 and an oversized body 413, each recording nothing and reading nothing;
  and the telemetry of all of these holds the provider, the outcome and the status only.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshBpmn.Triggers.Correlator
  alias AshOperations.Webhook.Signature
  alias Battery.Bpmn.{Definition, Instance, Invoker, ProcessEvent, Token}
  alias Battery.Operations.{ActivationSettled, Delivery, FollowUp, Router, Submission, Webhook}
  alias Battery.OperationsStub

  @secret "battery-synthetic-secret"
  @activation_id "act-42"

  # What a host's event source hands the engine for an envelope that reached its log: the
  # published context contract (`AshBpmn.EventSource.context/1`).
  defmodule Events do
    def context(%ActivationSettled{} = message) do
      %{
        "event" => %{
          "id" => message.id,
          "sequence" => 0,
          "occurred_at" => message.time,
          "resource" => "Battery.Operations.ActivationSettled",
          "action" => "emit",
          "action_type" => "create",
          "record_id" => message.id,
          "version" => 1
        },
        "actor" => %{},
        "tenant" => %{},
        "data" => %{
          "event_id" => message.event_id,
          "source" => message.source,
          "type" => message.type,
          "subject" => message.subject,
          "data" => message.data
        },
        "changed" => %{},
        "metadata" => %{}
      }
    end
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    for table <- ~w(battery_activation_settled battery_deliveries battery_submissions
                    bpmn_definitions bpmn_instances bpmn_tokens bpmn_process_events) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    AshBpmn.Runtime.Oban.TestJobs.clear()
    Invoker.clear_calls()

    # The provider says the activation is `active`, however the webhook describes it.
    count =
      OperationsStub.install!(fn %{method: "GET", request_path: "/activations/" <> id} = conn ->
        OperationsStub.json(conn, 200, %{"id" => id, "status" => "active"})
      end)

    handler = "battery-webhook-#{System.unique_integer([:positive])}"
    me = self()

    :telemetry.attach(
      handler,
      [:battery_operations, :webhook, :received],
      fn _event, _measurements, metadata, _config -> send(me, {:webhook, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    submission =
      Ash.create!(Submission, %{data_class: "general", activation_id: @activation_id},
        action: :record_activation
      )

    definition =
      publish_process!("battery_activation_wait", Battery.Fixtures.activation_wait_process())

    {:ok, instance} =
      AshBpmn.start_instance(Battery.Domain,
        process: "battery_activation_wait",
        subject: submission
      )

    %{count: count, instance: instance, definition: definition}
  end

  test "the process parks on the activation id; a signed webhook only records the id", ctx do
    assert [%{status: :waiting} = parked] = tokens_at(ctx.instance, "AwaitActivation")

    assert {parked.correlation_key, parked.subscription_signature} ==
             {@activation_id, "message:Battery.Operations.ActivationSettled:emit"}

    assert Ash.get!(Instance, ctx.instance.id).status == :running

    conn = post(%{"activationId" => @activation_id}, "delivery-1")
    assert {conn.status, conn.resp_body} == {204, ""}
    assert_received {:webhook, %{outcome: :enqueued, status: 204}}

    # One delivery holding the id and nothing else, and the provider has not been asked.
    assert [delivery] = Ash.read!(Delivery)

    assert {delivery.provider, delivery.dedup_key, delivery.activation_id, delivery.status} ==
             {"battery-registry", "delivery-1", @activation_id, :received}

    assert ctx.count.("GET", "/activations/" <> @activation_id) == 0
    assert Ash.read!(ActivationSettled) == []
    assert Ash.get!(Instance, ctx.instance.id).status == :running
  end

  test "the follow-up reads the provider once, and the nudge is not a fact", ctx do
    # The webhook CLAIMS the activation was revoked. Only its id is kept.
    conn = post(%{"activationId" => @activation_id, "status" => "revoked"}, "delivery-2")
    assert conn.status == 204

    assert FollowUp.drain() == 1
    assert ctx.count.("GET", "/activations/" <> @activation_id) == 1

    assert [message] = Ash.read!(ActivationSettled)

    assert {message.type, message.subject, message.data} ==
             {"registry.activation.settled", @activation_id, %{"status" => "active"}}

    assert [%{status: :followed_up}] = Ash.read!(Delivery)

    # Handed to the engine's correlator, as a host's sweep would, the envelope wakes the
    # process, which routes on what the read said, not on what the webhook claimed.
    deliver!(message)
    done = Ash.get!(Instance, ctx.instance.id)
    assert {done.status, done.outcome} == {:completed, "activated"}
    assert tokens_at(ctx.instance, "Activated") |> length() == 1
    assert tokens_at(ctx.instance, "NotActivated") == []
  end

  test "a redelivery is a duplicate and moves nothing", ctx do
    assert post(%{"activationId" => @activation_id}, "delivery-3").status == 204
    assert FollowUp.drain() == 1
    [message] = Ash.read!(ActivationSettled)
    deliver!(message)

    flush_telemetry()
    assert post(%{"activationId" => @activation_id}, "delivery-3").status == 204
    assert_received {:webhook, %{outcome: :duplicate, status: 204}}

    # Still one delivery; nothing to follow up, so no request; one wake, one end token.
    assert [_one] = Ash.read!(Delivery)
    assert FollowUp.drain() == 0
    assert ctx.count.("GET", "/activations/" <> @activation_id) == 1
    assert [_one] = Ash.read!(ActivationSettled)

    deliver!(message)
    assert [_one] = heard(ctx.instance)
    assert tokens_at(ctx.instance, "Activated") |> length() == 1
  end

  test "a bad or stale signature is 401 and an oversized body 413: nothing recorded or read",
       ctx do
    body = Jason.encode!(%{"activationId" => @activation_id})

    bad = post(body, "delivery-4", secret: "not-the-secret")
    assert bad.status == 401
    assert_received {:webhook, %{outcome: :unauthorized, status: 401}}

    # Signed correctly, but five minutes and a second ago.
    old = Integer.to_string(System.os_time(:second) - 301)

    stale_headers = [
      {"x-battery-timestamp", old},
      {"x-battery-signature", Signature.hmac_sha256_hex(@secret, [old, ".", body])},
      {"x-battery-delivery", "delivery-5"}
    ]

    assert send_raw(body, stale_headers).status == 401

    unsigned = send_raw(body, [{"x-battery-delivery", "delivery-6"}])
    assert unsigned.status == 401

    big =
      Jason.encode!(%{"activationId" => @activation_id, "pad" => String.duplicate("a", 4_096)})

    assert post(big, "delivery-7").status == 413
    assert_received {:webhook, %{outcome: :too_large, status: 413}}

    assert Ash.read!(Delivery) == []
    assert FollowUp.drain() == 0
    assert ctx.count.("GET", "/activations/" <> @activation_id) == 0
  end

  test "an id that is not id-shaped is rejected, and telemetry carries no identifier", ctx do
    assert post(%{"activationId" => "../../etc/passwd"}, "delivery-8").status == 400
    assert post(%{"activationId" => @activation_id}, "delivery-9").status == 204

    metadata = collect_telemetry()
    assert length(metadata) >= 2

    for meta <- metadata do
      assert meta |> Map.keys() |> Enum.sort() == [:outcome, :provider, :status]
      assert meta.provider == "battery-registry"

      for needle <- [@activation_id, "delivery-8", "delivery-9", @secret, "passwd"] do
        refute inspect(meta) =~ needle
      end
    end

    assert ctx.count.("GET", "/activations/" <> @activation_id) == 0
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp post(payload, delivery, opts \\ [])

  defp post(payload, delivery, opts) when is_map(payload),
    do: post(Jason.encode!(payload), delivery, opts)

  defp post(body, delivery, opts) when is_binary(body) do
    secret = Keyword.get(opts, :secret, @secret)
    send_raw(body, Webhook.sign(secret, body, delivery))
  end

  defp send_raw(body, headers) do
    :post
    |> Plug.Test.conn("/webhooks/battery-registry", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    end)
    |> Router.call(Router.init([]))
  end

  defp collect_telemetry(acc \\ []) do
    receive do
      {:webhook, meta} -> collect_telemetry([meta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp flush_telemetry, do: collect_telemetry()

  # What a host's sweep does with an envelope in its log.
  defp deliver!(message) do
    domain = Battery.Domain
    resources = AshBpmn.Runtime.DomainResolver.resolve!(domain)
    scope = %AshBpmn.Scope{AshBpmn.Scope.from_job(%{}, :sweep) | domain: domain}

    ctx = %{
      scope: scope,
      tenant: nil,
      domain: domain,
      resources: resources,
      event_source: Events
    }

    Correlator.dispatch_event(message, [], ctx)
  end

  defp heard(instance) do
    ProcessEvent
    |> Ash.Query.filter(instance_id == ^instance.id and kind == :message_received)
    |> Ash.read!()
  end

  defp tokens_at(instance, node_id) do
    Token
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!()
  end

  defp publish_process!(key, xml) do
    defn = Definition.create!(%{key: key, name: "Battery #{key}", xml: xml})

    if defn.graph do
      Battery.Repo.query!(
        "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
      )

      Definition.by_key_version!(defn.key, defn.version)
    else
      raise "Definition #{key} failed to compile: #{inspect(defn.errors)}"
    end
  end
end
