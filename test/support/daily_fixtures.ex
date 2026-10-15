defmodule AshEnterprise.Test.DailyFixtures do
  @moduledoc """
  SYNTHETIC data for the daily-loop surface tests (Today, Calendar, Inbox,
  Slack, People, Approvals, Accounts, Erasure): a seeded tenant whose admin
  carries their `ActorContext`, calendar events relative to now, a morning
  brief parked on its BPMN approval task, conversations and linked accounts.
  Every person is on `example.test`; nothing here is real.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Bpmn.Definition
  alias AshEnterprise.Canonical.{CalendarEvent, Conversation, Message, Person}
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  @doc "A seeded tenant: `%{actor:, user:, tenant:, organization:}`. `operator?: true` grants the Platform Operator role."
  def tenant!(opts \\ []) do
    n = System.unique_integer([:positive])
    email = Keyword.get(opts, :email, "daily-#{n}@example.test")

    seeded =
      Seeder.seed_tenant(name: "Daily #{n}", unique_name: "daily-#{n}", email: email)

    if Keyword.get(opts, :operator?, false), do: Seeder.grant_platform_operator(seeded.user)

    %{
      actor: actor(seeded.user),
      user: seeded.user,
      tenant: seeded.organization.id,
      organization: seeded.organization,
      email: email
    }
  end

  @doc """
  A member of `admin`'s tenant, in its root business unit, holding one role that
  grants exactly `grants` (`{resource, verb, depth}`; `[]` grants nothing):
  `%{actor:, user:, tenant:, email:}`.
  """
  def member!(admin, role_name, grants) do
    actor = SystemActor.seed()
    tenant = admin.tenant
    unit_id = admin.user.owning_business_unit_id

    role =
      Security.Role
      |> Ash.Changeset.for_create(
        :create,
        %{name: role_name, owning_business_unit_id: unit_id},
        actor: actor,
        tenant: tenant
      )
      |> Ash.create!()

    for {resource, verb, depth} <- grants do
      name = inspect(resource)

      privilege =
        Security.Privilege
        |> Ash.Query.filter(resource_name == ^name and access_right == ^verb)
        |> Ash.read_one!(authorize?: false)

      Security.RolePrivilege
      |> Ash.Changeset.for_create(
        :create,
        %{role_id: role.id, privilege_id: privilege.id, depth: depth},
        actor: actor,
        tenant: tenant
      )
      |> Ash.create!()
    end

    email = "member-#{System.unique_integer([:positive])}@example.test"

    user =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: "password1234", password_confirmation: "password1234"},
        authorize?: false
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:assign_to_business_unit, %{owning_business_unit_id: unit_id},
        authorize?: false
      )
      |> Ash.update!()

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{user_id: user.id, role_id: role.id, scoping_business_unit_id: unit_id},
      actor: actor,
      tenant: tenant
    )
    |> Ash.create!()

    %{actor: actor(user), user: user, tenant: tenant, email: email}
  end

  @doc "Deactivates a member's account (offboarding) and returns them with a fresh actor."
  def deactivate!(%{user: user} = member) do
    user =
      user
      |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false)
      |> Ash.update!()

    %{member | user: user, actor: actor(user)}
  end

  @doc """
  Publishes `morning.brief` as the platform baseline, as the dogfood instance
  runs it: every tenant resolves it with nothing of its own provisioned.
  Call `AshEnterprise.Process.Resolver.forget_platform_tenant/0` on exit.
  """
  def platform_brief_process! do
    AshEnterprise.Process.Resolver.forget_platform_tenant()
    platform = Seeder.seed_platform_organization()
    opts = [actor: SystemActor.process(), tenant: platform.id]

    %{
      key: "morning.brief",
      name: "Morning brief",
      xml: File.read!("priv/bpmn/morning_brief.bpmn")
    }
    |> Definition.create!(opts)
    |> Definition.publish!(opts)
  end

  @doc "A user with their authorization context attached, as a request carries it."
  def actor(user), do: ActorContext.attach(user, ActorContext.build(user))

  @doc "An erasure scope for synthetic content."
  def scope!(ref \\ "test:daily-#{System.unique_integer([:positive])}") do
    AshEnterprise.Erasure.ensure_scope!(:connection, ref, %{}, actor: SystemActor.oban())
  end

  @doc "A person, upserted on email."
  def person!(%{user: user, tenant: tenant}, email, name) do
    Person
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(owner(user), %{email: email, name: name}),
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  @doc "A calendar event `minutes_from_now` ahead, lasting `minutes`."
  def event!(%{user: user, tenant: tenant} = ctx, title, minutes_from_now, minutes, opts \\ []) do
    starts_at = DateTime.add(DateTime.utc_now(), minutes_from_now, :minute)

    organizer =
      opts[:organizer] && person!(ctx, elem(opts[:organizer], 0), elem(opts[:organizer], 1))

    CalendarEvent
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(owner(user), %{
        title: title,
        starts_at: starts_at,
        ends_at: DateTime.add(starts_at, minutes, :minute),
        location: opts[:location],
        status: Keyword.get(opts, :status, :confirmed),
        external_system: "test",
        external_id: "evt-#{System.unique_integer([:positive])}",
        organizer_id: organizer && organizer.id,
        erasure_scope_id: (opts[:scope] || scope!()).id
      }),
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  @doc "A conversation in `system` (`gmail` or `slack`) with one inbound message."
  def conversation!(%{user: user, tenant: tenant} = ctx, system, subject, body) do
    scope = scope!()
    sender = person!(ctx, "sender-#{System.unique_integer([:positive])}@example.test", "Sender")

    conversation =
      Conversation
      |> Ash.Changeset.for_create(
        :upsert_from_source,
        Map.merge(owner(user), %{
          subject: subject,
          participants: %{},
          external_system: system,
          external_id: "conv-#{System.unique_integer([:positive])}",
          erasure_scope_id: scope.id
        }),
        tenant: tenant,
        authorize?: false
      )
      |> Ash.create!()

    Message
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(owner(user), %{
        body: body,
        sent_at: DateTime.utc_now(),
        direction: :inbound,
        external_system: system,
        external_id: "msg-#{System.unique_integer([:positive])}",
        conversation_id: conversation.id,
        sender_id: sender.id,
        erasure_scope_id: scope.id
      }),
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!()

    conversation
  end

  @doc "Publishes `morning.brief` and starts today's brief: it parks on its approval task."
  def brief!(%{actor: actor, tenant: tenant}) do
    xml = File.read!("priv/bpmn/morning_brief.bpmn")

    unless Definition
           |> Ash.Query.filter(key == "morning.brief" and status == :published)
           |> Ash.exists?(authorize?: false, tenant: tenant) do
      Definition.create!(%{key: "morning.brief", name: "Morning brief", xml: xml},
        actor: SystemActor.process(),
        tenant: tenant
      )
      |> Definition.publish!(actor: SystemActor.process(), tenant: tenant)
    end

    brief =
      MorningBrief
      |> Ash.Changeset.for_create(
        :start_for_date,
        %{brief_date: AshEnterprise.Platform.LocalTime.today()},
        actor: actor,
        tenant: tenant
      )
      |> Ash.create!()

    AshBpmn.start_instance!(AshEnterprise.Bpmn,
      process: "morning.brief",
      subject: brief,
      actor: actor,
      tenant: tenant
    )

    brief
  end

  @doc "Reloads a brief, unauthorized (assertions only)."
  def reload_brief!(%{id: id}, tenant) do
    MorningBrief
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  @doc "A linked account for `key`, owned by the context's user."
  def linked_account!(%{actor: actor, tenant: tenant}, key, label \\ "work") do
    AshEnterprise.Integration.LinkedAccount.link!(
      %{
        provider_config_key: key,
        connection_id: "synthetic-#{key}-#{System.unique_integer([:positive])}",
        label: label
      },
      actor: actor,
      tenant: tenant
    )
  end

  defp owner(user) do
    %{
      owner_id: user.id,
      owner_type: :user,
      owning_user_id: user.id,
      owning_business_unit_id: user.owning_business_unit_id
    }
  end
end
