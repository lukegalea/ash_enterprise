defmodule AshEnterprise.Integration.Outbound.EndpointTest do
  @moduledoc """
  Registering an outbound webhook endpoint: who may, what it may subscribe to, that another
  tenant's endpoint is invisible and hears nothing, and the signing secret's life (shown
  once, never in the audit log, unreadable once its erasure scope is shredded).
  """

  # async: false: the transport's and the egress guard's application env are node-global.
  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, tenant!: 1, member!: 3]
  import AshEnterprise.Test.OutboundWebhooks

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Erasure
  alias AshEnterprise.Integration
  alias AshEnterprise.Integration.Outbound.Delivery
  alias AshEnterprise.Platform.AutomationPrincipal
  alias AshEnterprise.Security.ActorContext

  setup do
    stub_network!()
    %{admin: tenant!()}
  end

  test "a user without the endpoint privilege cannot register one (Forbidden)", %{admin: admin} do
    member = member!(admin, "No webhooks", [])

    assert {:error, %Ash.Error.Forbidden{}} =
             Integration.register_webhook_endpoint(
               %{
                 url: "https://hooks.example.test/in",
                 event_types: ["ash_enterprise.team.create"]
               },
               actor: member.actor,
               tenant: member.tenant
             )

    # Reading is a grant too: nothing the member can see.
    endpoint!(admin)

    assert {:ok, []} =
             Integration.list_webhook_endpoints(actor: member.actor, tenant: member.tenant)
  end

  test "an event type outside the catalogue is Invalid", %{admin: admin} do
    assert {:error, %Ash.Error.Invalid{} = error} =
             Integration.register_webhook_endpoint(
               %{
                 url: "https://hooks.example.test/in",
                 event_types: ["ash_enterprise.nothing.create"]
               },
               actor: admin.actor,
               tenant: admin.tenant
             )

    assert Exception.message(error) =~ "not a subscribable event type"

    # The integration domain's own resources are not in the catalogue: no delivery is ever
    # the event that causes another.
    assert {:error, %Ash.Error.Invalid{}} =
             Integration.register_webhook_endpoint(
               %{
                 url: "https://hooks.example.test/in",
                 event_types: ["ash_enterprise.endpoint.create"]
               },
               actor: admin.actor,
               tenant: admin.tenant
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Integration.register_webhook_endpoint(
               %{url: "https://hooks.example.test/in", event_types: []},
               actor: admin.actor,
               tenant: admin.tenant
             )
  end

  test "a URL that is not https on 443, or names a private address, is Invalid", %{admin: admin} do
    for url <- [
          "http://hooks.example.test/in",
          "https://hooks.example.test:8443/in",
          "https://user:secret@hooks.example.test/in",
          "https://169.254.169.254/latest/meta-data",
          "https://127.0.0.1/in"
        ] do
      assert {:error, %Ash.Error.Invalid{}} =
               Integration.register_webhook_endpoint(
                 %{url: url, event_types: ["ash_enterprise.team.create"]},
                 actor: admin.actor,
                 tenant: admin.tenant
               ),
             "#{url} was accepted"
    end
  end

  test "an endpoint in another tenant is invisible and never receives this tenant's events", %{
    admin: admin
  } do
    other = tenant!()
    theirs = endpoint!(other)

    assert {:ok, []} =
             Integration.list_webhook_endpoints(actor: admin.actor, tenant: admin.tenant)

    assert {:error, _} =
             Integration.get_webhook_endpoint(theirs.id, actor: admin.actor, tenant: admin.tenant)

    team!(admin, "Not theirs")
    fan_out!(theirs)

    assert deliveries(theirs) == []

    assert {:ok, [_ | _]} =
             Integration.list_webhook_endpoints(actor: other.actor, tenant: other.tenant)
  end

  test "the secret is shown once and is nil in the audit event", %{admin: admin} do
    endpoint = endpoint!(admin)
    secret = endpoint.__metadata__.signing_secret

    assert "whsec_" <> key = secret
    assert byte_size(Base.decode64!(key)) == 32

    # Read again, the endpoint carries no secret: only the sealed value, which is sensitive.
    {:ok, reread} =
      Integration.get_webhook_endpoint(endpoint.id, actor: admin.actor, tenant: admin.tenant)

    refute Map.has_key?(reread.__metadata__, :signing_secret)
    refute reread.sealed_secret =~ key

    events =
      EventLog
      |> Ash.Query.filter(record_id == ^endpoint.id)
      |> Ash.read!(authorize?: false, tenant: admin.tenant)

    assert [%{data: data, changed_attributes: changed}] = events
    assert Map.get(data, "sealed_secret") == nil
    assert Map.get(changed, "sealed_secret") == nil
    refute inspect(events, limit: :infinity, printable_limit: :infinity) =~ key

    # Rotating hands back a different secret, once, and is audited the same way.
    {:ok, rotated} =
      Integration.rotate_webhook_secret(endpoint, actor: admin.actor, tenant: admin.tenant)

    assert "whsec_" <> new_key = rotated.__metadata__.signing_secret
    refute new_key == key
  end

  test "shredding the endpoint's scope makes the secret unreadable", %{admin: admin} do
    receiver!()
    endpoint = endpoint!(admin)
    scope = Erasure.get_scope!(endpoint.erasure_scope_id, authorize?: false)
    assert scope.kind == :connection
    assert scope.ref == "outbound_endpoint:#{endpoint.id}"

    team!(admin, "Before the shred")
    fan_out!(endpoint)

    operator = tenant!(operator?: true)
    Erasure.shred_scope!(scope, scope.ref, "endpoint retired", actor: operator.actor)

    # Nothing is sent: the transport cannot open the secret, so the delivery is refused.
    [delivery] = deliveries(endpoint)
    assert %Delivery{state: :refused, last_reason: "secret_shredded"} = deliver!(delivery)
    refute_received {:received, _}

    # And no new secret can be sealed under a shredded scope.
    assert {:error, %Ash.Error.Invalid{} = error} =
             Integration.rotate_webhook_secret(reload(endpoint),
               actor: admin.actor,
               tenant: admin.tenant
             )

    refute Enum.any?(error.errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  test "an automation principal cannot register an endpoint or rotate its secret", %{admin: admin} do
    # The principal acting for the administrator with the administrator's whole authority:
    # the grant is there, and still the action is a person's own.
    principal =
      AutomationPrincipal.acting(
        AutomationPrincipal.recipe_runner(),
        admin.user.id,
        "outbound-webhook-test",
        ActorContext.build(admin.user, tenant: admin.tenant)
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Integration.register_webhook_endpoint(
               %{
                 url: "https://hooks.example.test/in",
                 event_types: ["ash_enterprise.team.create"]
               },
               actor: principal,
               tenant: admin.tenant
             )

    endpoint = endpoint!(admin)

    assert {:error, %Ash.Error.Forbidden{}} =
             Integration.rotate_webhook_secret(reload(endpoint),
               actor: principal,
               tenant: admin.tenant
             )
  end
end
