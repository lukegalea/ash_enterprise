defmodule AshEnterpriseWeb.DeliveriesSurfaceTest do
  @moduledoc """
  The webhook deliveries surface (`AshOperations.A2ui.Deliveries`) bound to this application's
  delivery resource, and the resource's collision with the platform base: the instantiated
  `AshOperations.Resources.Delivery` still gets the application's grants, machinery-only
  actions and audit row.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 1]
  import Phoenix.LiveViewTest

  require Ash.Query

  alias AshEnterprise.Integration
  alias AshEnterprise.Integration.Operations.Delivery
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Surfaces

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp pushed(view) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    JSON.encode!(messages)
  end

  defp deliver!(attrs \\ %{}) do
    Integration.receive_provider_delivery!(
      Map.merge(
        %{
          provider: "credential-registry",
          dedup_key: "d-#{System.unique_integer([:positive])}",
          subject_id: "act-1",
          event_type: "activation.updated"
        },
        attrs
      ),
      actor: SystemActor.oban()
    )
  end

  describe "the instantiated resource on the platform base" do
    test "record is idempotent on (provider, dedup_key) and stamps received_at" do
      first = deliver!(%{dedup_key: "same"})
      again = deliver!(%{dedup_key: "same"})

      assert first.id == again.id
      assert first.state == :received
      assert first.signature_verdict == :valid
      assert %DateTime{} = first.received_at
    end

    test "record, mark_followed_up and follow_up stay machinery-only" do
      delivery = deliver!()
      %{actor: person} = tenant!(operator?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Integration.receive_provider_delivery(
                 %{provider: "x", dedup_key: "k", subject_id: "s"},
                 actor: person
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               delivery
               |> Ash.Changeset.for_update(:mark_followed_up, %{outcome: :ignored}, actor: person)
               |> Ash.update()

      settled =
        delivery
        |> Ash.Changeset.for_update(:mark_followed_up, %{outcome: :ignored},
          actor: SystemActor.oban()
        )
        |> Ash.update!()

      assert settled.state == :ignored
      assert %DateTime{} = settled.followed_up_at
    end

    test "the delivery is tenantless and audited" do
      assert Ash.Resource.Info.multitenancy_strategy(Delivery) == nil
      delivery = deliver!()

      assert [_ | _] =
               AshEnterprise.Audit.EventLog
               |> Ash.Query.filter(record_id == ^delivery.id and action == :record)
               |> Ash.read!(authorize?: false)
    end
  end

  describe "the surface" do
    test "is registered behind the operator door and derives valid A2UI messages" do
      entry = Enum.find(Surfaces.all(), &(&1.key == :deliveries))

      assert entry.path == "/app/deliveries"
      assert entry.door == :operator
      assert entry.resource == Delivery

      messages = AshA2ui.Info.build_surface(AshEnterpriseWeb.A2ui.DeliveriesUI)
      assert Enum.any?(messages, &Map.has_key?(&1, "createSurface"))
    end

    test "the platform operator sees a delivery; another administrator is turned away", %{
      conn: conn
    } do
      deliver!(%{subject_id: "act-visible"})

      operator = tenant!(operator?: true)
      {:ok, view, _html} = live(sign_in(conn, operator.user), "/app/deliveries")
      assert pushed(view) =~ "act-visible"
      render_async(view)

      admin = tenant!([])

      assert {:error, {:redirect, %{to: "/app"}}} =
               live(sign_in(build_conn(), admin.user), "/app/deliveries")
    end
  end
end
