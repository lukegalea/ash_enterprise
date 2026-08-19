defmodule AshEnterprise.Legacy.ReadModelTest do
  @moduledoc """
  The strangler read model over `legacy.users`, and the bridge that makes a write
  by the legacy application visible here.

  Two different things are being checked, and they fail in different ways:

    * **The mapping** — does a legacy row arrive as the platform resource it is
      declared to be. A mistake here is visible: wrong values on screen.
    * **The bridge** — does a legacy write reach the topic the LiveView listens
      on. A mistake here is *invisible*: nothing raises, nothing is logged, the
      page simply stops updating. Every link in that chain is opt-in and
      independently breakable, which is why the last two tests assert the joint
      between the resource's publications and the surface's subscriptions rather
      than trusting that two lists of strings stay in step.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Legacy.Estate
  alias AshEnterprise.Security.ActorContext

  setup do
    seeded =
      case AshEnterprise.Platform.Seeder.seed_legacy_estate() do
        :already_seeded ->
          raise "the legacy estate should not survive the sandbox transaction"

        seeded ->
          seeded
      end

    admin =
      ActorContext.attach(
        seeded.user,
        ActorContext.build(seeded.user, tenant: seeded.organization.id)
      )

    %{seeded: seeded, admin: admin, tenant: Estate.organization_id()}
  end

  defp read!(ctx) do
    AshEnterprise.Legacy.User
    |> Ash.Query.for_read(:read, %{}, actor: ctx.admin, tenant: ctx.tenant)
    |> Ash.read!()
  end

  describe "the mapping" do
    test "legacy rows arrive as ordinary platform records", ctx do
      users = read!(ctx)

      assert users != []
      assert Enum.all?(users, &(&1.organization_id == Estate.organization_id()))
      assert Enum.all?(users, &(&1.owning_business_unit_id == Estate.business_unit_id()))
    end

    test "a name no splitting rule fixes survives the projection", ctx do
      josefa = Enum.find(read!(ctx), &(&1.login == "jdelacruz"))

      # The reason `full_name` is read-only in the mapping, stated as data.
      assert josefa.full_name == "Josefa de la Cruz"
    end

    test "a null last_name does not blank the whole name", ctx do
      # SQL's `||` propagates NULL, so every operand of the concatenation is
      # null-defaulted. Without that, one absent name empties the column.
      legacy_id = insert_legacy_user!(first_name: "Solo", last_name: nil)

      user = Enum.find(read!(ctx), &(&1.legacy_id == legacy_id))

      assert user.full_name =~ "Solo"
    end

    test "five legacy states collapse onto two platform statuses", ctx do
      by_login = Map.new(read!(ctx), &{&1.login, &1})

      assert by_login["awhitfield"].legacy_state == "active"
      assert by_login["awhitfield"].lifecycle_status == :active

      # passive and suspended are both "not active" here, and there is no third
      # option to put them in. That is the lossy half of the mapping, which is
      # why writing `lifecycle_status` back is refused with a reason.
      assert by_login["pending.contractor"].legacy_state == "passive"
      assert by_login["pending.contractor"].lifecycle_status == :inactive
      assert by_login["lfeng"].legacy_state == "suspended"
      assert by_login["lfeng"].lifecycle_status == :inactive
    end

    test "acts_as_paranoid and soft delete are the same thing", ctx do
      # `legacy.users.deleted_at` maps onto the attribute AshArchival already
      # adds, so a row the legacy application deleted is filtered out here
      # without either application being told about the other. tobrien is seeded
      # with a `deleted_at`.
      logins = Enum.map(read!(ctx), & &1.login)

      refute "tobrien" in logins
      assert "awhitfield" in logins
    end

    test "the derived uuid is the one Elixir computes independently", ctx do
      user = Enum.find(read!(ctx), &(&1.login == "awhitfield"))

      # A drift between the SQL derivation and the Elixir one does not raise --
      # it makes `Ash.get/2` find nothing for rows that exist, which is exactly
      # how the notification bridge would fail silently.
      assert {:ok, ^user} =
               Ash.get(AshEnterprise.Legacy.User, user.id,
                 actor: ctx.admin,
                 tenant: ctx.tenant
               )
    end
  end

  describe "tenant isolation" do
    test "the greenfield tenant cannot see the legacy estate", ctx do
      # Plan §4.2: a tenant with one member proves nothing about isolation. The
      # evidence that multitenancy survived being *added* to data that never had
      # it is that these rows are invisible from the other organization.
      greenfield =
        AshEnterprise.Platform.Seeder.seed_tenant(
          unique_name: "greenfield-#{System.unique_integer([:positive])}"
        )

      other_admin =
        ActorContext.attach(
          greenfield.user,
          ActorContext.build(greenfield.user, tenant: greenfield.organization.id)
        )

      rows =
        AshEnterprise.Legacy.User
        |> Ash.Query.for_read(:read, %{},
          actor: other_admin,
          tenant: greenfield.organization.id
        )
        |> Ash.read!()

      assert rows == []
      refute read!(ctx) == []
    end
  end

  describe "the notification bridge" do
    test "a legacy write reaches the topic the surface subscribes to", ctx do
      # The listener is not started under test (`:legacy_listener?` is false --
      # LISTEN needs a connection outside the sandbox pool), so this drives the
      # half of the chain that runs in this application: re-read through Ash,
      # synthesize the notification, dispatch it through the resource's
      # notifiers, and land on Phoenix.PubSub.
      Phoenix.PubSub.subscribe(AshEnterprise.PubSub, "legacy_users:created")

      legacy_id = insert_legacy_user!(first_name: "Bridge", last_name: "Check")

      AshStrangler.Listener.notify(
        %{resource: AshEnterprise.Legacy.User, legacy_id: legacy_id, op: :insert},
        authorize?: false,
        tenant: ctx.tenant
      )

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "legacy_users:created",
                       payload: %Ash.Notifier.Notification{} = notification
                     },
                     2_000

      assert notification.resource == AshEnterprise.Legacy.User
      assert notification.data.full_name == "Bridge Check"

      # The origin is what a consumer that cares uses to tell a legacy write
      # from an Ash one.
      assert notification.metadata.ash_strangler.origin == :legacy
    end

    test "the write is attributed to a synthesized action, because no Ash action ran" do
      Phoenix.PubSub.subscribe(AshEnterprise.PubSub, "legacy_users:created")

      legacy_id = insert_legacy_user!(first_name: "Synth", last_name: "Action")

      AshStrangler.Listener.notify(
        %{resource: AshEnterprise.Legacy.User, legacy_id: legacy_id, op: :insert},
        authorize?: false
      )

      assert_receive %Phoenix.Socket.Broadcast{payload: notification}, 2_000

      # This is why the resource must use `publish_all` and not `publish`:
      # `publish_all` matches on the action's type, which is `:create`;
      # `publish :some_action` would match on the name, which is a name this
      # resource does not declare and never will.
      assert notification.action.name == :legacy_write
      assert notification.action.type == :create
    end

    test "every topic the surface subscribes to is one the resource publishes" do
      # The one genuinely fragile joint in the chain. `AshA2ui.LiveRenderer` does
      # not introspect publications -- it cannot -- so the topic list on the
      # LiveView and the `pub_sub` block on the resource are two independent
      # spellings of the same strings. A typo in either produces a surface that
      # silently never updates, with nothing logged anywhere.
      prefix = Ash.Notifier.PubSub.Info.prefix(AshEnterprise.Legacy.User)

      published =
        AshEnterprise.Legacy.User
        |> Ash.Notifier.PubSub.Info.publications()
        |> Enum.flat_map(fn publication ->
          Enum.map(List.wrap(publication.topic), &"#{prefix}:#{&1}")
        end)
        |> MapSet.new()

      subscribed =
        AshEnterpriseWeb.A2uiLive.LegacyUsers.__ash_a2ui_config__().pubsub.topics
        |> MapSet.new()

      assert MapSet.equal?(subscribed, published),
             """
             The surface's topics and the resource's publications have drifted.

               subscribed only: #{inspect(MapSet.to_list(MapSet.difference(subscribed, published)))}
               published only:  #{inspect(MapSet.to_list(MapSet.difference(published, subscribed)))}
             """
    end

    test "the surface subscribes on the server the endpoint broadcasts through" do
      # `pub_sub do module AshEnterpriseWeb.Endpoint end` broadcasts through the
      # endpoint's configured pubsub_server. Subscribing to a different server is
      # the other way these two halves can pass every other check and still never
      # meet.
      endpoint_server = AshEnterpriseWeb.Endpoint.config(:pubsub_server)

      assert AshEnterpriseWeb.A2uiLive.LegacyUsers.__ash_a2ui_config__().pubsub.module ==
               endpoint_server
    end
  end

  # Writes straight to the legacy table, the way the old application would --
  # no Ash, no changeset, no policies.
  defp insert_legacy_user!(opts) do
    login = "test-#{System.unique_integer([:positive])}"

    %{rows: [[id]]} =
      AshEnterprise.Repo.query!(
        """
        INSERT INTO legacy.users (login, email, first_name, last_name, state, created_at, updated_at)
        VALUES ($1, $2, $3, $4, 'active', now(), now())
        RETURNING id
        """,
        [
          login,
          "#{login}@corp.example",
          Keyword.get(opts, :first_name),
          Keyword.get(opts, :last_name)
        ]
      )

    id
  end
end
