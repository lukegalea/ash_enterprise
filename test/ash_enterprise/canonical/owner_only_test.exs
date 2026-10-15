defmodule AshEnterprise.Canonical.OwnerOnlyTest do
  @moduledoc """
  One person's projected mail and Slack — `Conversation`, `Message`, `Person`
  — and the joins derived from them (`ConversationParticipant`,
  `EventAttendee`: who talks with whom, who meets whom) are readable by that
  person and nobody else in the tenant (ADR 0042,
  `AshEnterprise.Security.Privilege.owner_only?/1`): not another
  Administrator, not a manager through hierarchy security, and no role can be
  granted wider than `:basic` on them.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Accounts.User

  alias AshEnterprise.Canonical.{
    CalendarEvent,
    Conversation,
    ConversationParticipant,
    EventAttendee,
    Message,
    Person
  }

  alias AshEnterprise.Integration.{Landing, LinkedAccount}
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  @owner_only [Conversation, ConversationParticipant, EventAttendee, Message, Person]

  setup do
    unique = System.unique_integer([:positive])

    seeded =
      Seeder.seed_tenant(
        name: "Owner only #{unique}",
        unique_name: "owner-only-#{unique}",
        email: "alice-#{unique}@owner-only.synthetic.test"
      )

    org = seeded.organization
    alice = seeded.user

    # Bob: Alice's manager, and an Administrator of the same tenant.
    bob =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "bob-#{unique}@owner-only.synthetic.test",
          password: "password1234",
          password_confirmation: "password1234"
        },
        authorize?: false
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(
        :assign_to_business_unit,
        %{owning_business_unit_id: seeded.business_unit.id},
        authorize?: false
      )
      |> Ash.update!()

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{
        user_id: bob.id,
        role_id: seeded.role.id,
        scoping_business_unit_id: seeded.business_unit.id
      },
      tenant: org.id,
      authorize?: false
    )
    |> Ash.create!()

    alice =
      alice
      |> Ash.Changeset.for_update(:assign_manager, %{manager_id: bob.id}, authorize?: false)
      |> Ash.update!()

    account =
      LinkedAccount.link!(
        %{provider_config_key: "google-mail", connection_id: "conn-owner-only-#{unique}"},
        actor: actor(alice, org.id),
        tenant: org.id
      )

    {:ok, scope} = Landing.open(account)
    rows = project_for(alice, seeded.business_unit.id, org.id, scope.id, unique)

    on_exit(fn -> Application.delete_env(:ash_enterprise, :hierarchy_security) end)

    %{org: org, alice: alice, bob: bob, rows: rows, role: seeded.role}
  end

  test "the owner reads their own rows", ctx do
    for resource <- @owner_only do
      assert [row] = read(resource, ctx.alice, ctx.org.id)
      assert row.id == Map.fetch!(ctx.rows, resource).id
    end

    assert [%{body: "SYNTHETIC-OWNER-ONLY-BODY"}] = read(Message, ctx.alice, ctx.org.id)

    assert [%{subject: "SYNTHETIC-OWNER-ONLY-SUBJECT"}] =
             read(Conversation, ctx.alice, ctx.org.id)
  end

  test "another Administrator of the tenant reads none of them", ctx do
    for resource <- @owner_only do
      assert read(resource, ctx.bob, ctx.org.id) == []
      refute Ash.can?({Map.fetch!(ctx.rows, resource), :read}, actor(ctx.bob, ctx.org.id))
    end
  end

  test "a manager reads none of them through hierarchy security", ctx do
    Application.put_env(:ash_enterprise, :hierarchy_security, mode: :manager)

    for resource <- @owner_only do
      assert read(resource, ctx.bob, ctx.org.id) == []
    end
  end

  test "no role can be granted wider than :basic on them", ctx do
    for resource <- @owner_only, verb <- [:read, :write] do
      privilege = privilege!(resource, verb)
      refute privilege.can_be_global or privilege.can_be_deep or privilege.can_be_local
      assert privilege.can_be_basic

      grant = grant!(ctx, privilege)
      assert grant.depth == :basic

      assert {:error, %Ash.Error.Invalid{}} =
               grant
               |> Ash.Changeset.for_update(:update, %{depth: :global},
                 tenant: ctx.org.id,
                 authorize?: false
               )
               |> Ash.update()
    end
  end

  test "seed_privileges narrows a grant made before the resource was owner-only", ctx do
    privilege = privilege!(Message, :read)
    grant = grant!(ctx, privilege)

    # A stale :global grant, as an Administrator held before this change.
    Repo.query!("UPDATE role_privileges SET depth = 'global' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(grant.id)
    ])

    assert [_row] = read(Message, ctx.bob, ctx.org.id)

    Seeder.seed_privileges()

    assert Ash.get!(Security.RolePrivilege, grant.id, tenant: ctx.org.id, authorize?: false).depth ==
             :basic

    assert read(Message, ctx.bob, ctx.org.id) == []
    assert [_own] = read(Message, ctx.alice, ctx.org.id)
  end

  defp read(resource, user, org_id) do
    resource
    |> Ash.Query.for_read(:read, %{}, actor: actor(user, org_id), tenant: org_id)
    |> Ash.read!()
  end

  defp actor(user, org_id),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: org_id))

  defp privilege!(resource, verb) do
    name = inspect(resource)

    Security.Privilege
    |> Ash.Query.filter(resource_name == ^name and access_right == ^verb)
    |> Ash.read_one!(authorize?: false)
  end

  defp grant!(ctx, privilege) do
    Security.RolePrivilege
    |> Ash.Query.filter(role_id == ^ctx.role.id and privilege_id == ^privilege.id)
    |> Ash.read_one!(tenant: ctx.org.id, authorize?: false)
  end

  defp project_for(owner, business_unit_id, org_id, scope_id, unique) do
    owner_attrs = %{
      owner_id: owner.id,
      owner_type: :user,
      owning_user_id: owner.id,
      owning_business_unit_id: business_unit_id
    }

    opts = [tenant: org_id, authorize?: false]

    person =
      Person
      |> Ash.Changeset.for_create(
        :upsert_from_source,
        Map.merge(owner_attrs, %{email: "contact-#{unique}@owner-only.synthetic.test"}),
        opts
      )
      |> Ash.create!(upsert?: true, upsert_identity: :unique_email, upsert_fields: [])

    conversation =
      Conversation.upsert_from_source!(
        Map.merge(owner_attrs, %{
          external_system: "gmail",
          external_id: "owner-only-thread-#{unique}",
          subject: "SYNTHETIC-OWNER-ONLY-SUBJECT",
          participants: %{"person_ids" => [person.id]},
          erasure_scope_id: scope_id
        }),
        opts
      )

    message =
      Message.upsert_from_source!(
        Map.merge(owner_attrs, %{
          external_system: "gmail",
          external_id: "owner-only-message-#{unique}",
          body: "SYNTHETIC-OWNER-ONLY-BODY",
          sent_at: ~U[2026-10-01 12:00:00.000000Z],
          direction: :inbound,
          conversation_id: conversation.id,
          sender_id: person.id,
          erasure_scope_id: scope_id
        }),
        opts
      )

    CalendarEvent.upsert_from_source!(
      Map.merge(owner_attrs, %{
        external_system: "google_calendar",
        external_id: "owner-only-event-#{unique}",
        title: "SYNTHETIC-OWNER-ONLY-EVENT",
        starts_at: ~U[2026-10-01 12:00:00.000000Z],
        ends_at: ~U[2026-10-01 13:00:00.000000Z],
        erasure_scope_id: scope_id,
        attendees: [%{person_id: person.id, response_status: "accepted"}]
      }),
      opts
    )

    # The derived joins, written by the parents' upserts.
    [participant] = Ash.read!(ConversationParticipant, opts)
    [attendee] = Ash.read!(EventAttendee, opts)

    %{
      Person => person,
      Conversation => conversation,
      Message => message,
      ConversationParticipant => participant,
      EventAttendee => attendee
    }
  end
end
