defmodule AshEnterprise.Integration.ProjectionGuardsTest do
  @moduledoc """
  What the provider projectors must not write, whatever the payload says:

    * a `Person` another user owns is neither renamed nor linked (Slack, as
      Gmail and Calendar already did);
    * a sender-chosen display name or address cannot make a write fail, and
      a write that does fail is counted, not raised (an Ash error quotes the
      value it rejected);
    * nothing unsealed (`Person`) is derived from content whose scope was
      shredded between its landing and its projection.

  Records are built in memory (no provider call); every value is synthetic.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Canonical.{Conversation, Message, Person}
  alias AshEnterprise.Canonical.Projections
  alias AshEnterprise.Erasure
  alias AshEnterprise.Integration.{Landing, LinkedAccount}
  alias AshEnterprise.Integration.Slack.Records
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Test.CalendarFixtures, as: F

  @shared "shared.contact@example.synthetic.test"
  @probe "PROBE-SOURCED-NAME"

  defmodule AdmitAll do
    @moduledoc false
    # Test-only zone admission for Gmail; synthetic data only.
    @behaviour AshEnterprise.Canonical.Projections.ZoneGate
    @impl true
    def admit(_source, _context), do: :ok
  end

  setup do
    unique = System.unique_integer([:positive])

    seeded =
      Seeder.seed_tenant(
        name: "Guards #{unique}",
        unique_name: "guards-#{unique}",
        email: "alice-#{unique}@guards.synthetic.test"
      )

    org = seeded.organization
    Seeder.grant_platform_operator(seeded.user)
    alice = actor(seeded.user, org.id)
    bob = colleague(seeded.business_unit, "bob-#{unique}@guards.synthetic.test")

    # A contact bob's own sync projected first: his row, his name for them.
    theirs =
      Person
      |> Ash.Changeset.for_create(
        :upsert_from_source,
        %{
          email: @shared,
          name: "Name From Other Owner",
          owner_id: bob.id,
          owner_type: :user,
          owning_user_id: bob.id,
          owning_business_unit_id: seeded.business_unit.id
        },
        tenant: org.id,
        authorize?: false
      )
      |> Ash.create!()

    previous = Application.get_env(:ash_enterprise, Projections.Gmail)
    Application.put_env(:ash_enterprise, Projections.Gmail, zone_gate: AdmitAll)

    on_exit(fn -> restore_env(Projections.Gmail, previous) end)

    %{org: org, alice: alice, user: seeded.user, theirs: theirs, unique: unique}
  end

  # --- Slack ---------------------------------------------------------------------

  describe "Slack" do
    @describetag :tmp_dir

    setup ctx do
      declare_slack_zone(ctx.tmp_dir)

      # The operator's tags for the account: admissible in the test zone.
      account =
        ctx
        |> link!("slack")
        |> LinkedAccount.tag_for_zone!(%{data_class: :customer_confidential, residency: "CA"},
          tenant: ctx.org.id,
          authorize?: false
        )

      {:ok, scope} = Landing.open(account)
      %{account: account, scope: scope}
    end

    test "a Person another user owns is neither renamed nor linked", ctx do
      records =
        slack_world(ctx.account, [
          slack_user("U0SHARED", @probe, @shared),
          slack_user("U0OWN", "Own Contact", "own.contact@example.synthetic.test")
        ])

      assert {:ok, %{conversations: 1, messages: 2, people: 1, failed: 0}} =
               Projections.Slack.project(records, ctx.account, erasure_scope_id: ctx.scope.id)

      theirs = person!(ctx, @shared)
      assert theirs.id == ctx.theirs.id
      assert theirs.owner_id == ctx.theirs.owner_id
      assert theirs.name == "Name From Other Owner"

      [conversation] = Conversation.read!(tenant: ctx.org.id, authorize?: false)
      refute ctx.theirs.id in conversation.participants["person_ids"]
      assert [_own] = conversation.participants["person_ids"]

      messages = Message.read!(tenant: ctx.org.id, authorize?: false)
      shared_message = Enum.find(messages, &(&1.body == "SYNTHETIC-FROM-U0SHARED"))
      assert shared_message.sender_id == nil
      own_message = Enum.find(messages, &(&1.body == "SYNTHETIC-FROM-U0OWN"))
      assert own_message.sender_id == person!(ctx, "own.contact@example.synthetic.test").id
    end

    test "an over-long profile name is clipped and an over-long address is not linked", ctx do
      long_name = @probe <> String.duplicate("x", 400)
      long_email = String.duplicate("a", 330) <> "@example.synthetic.test"

      records =
        slack_world(ctx.account, [
          slack_user("U0LONG", long_name, "long.name@example.synthetic.test"),
          slack_user("U0MAIL", "Long Mail", long_email)
        ])

      assert {:ok, %{people: 1, messages: 2, failed: 0}} =
               Projections.Slack.project(records, ctx.account, erasure_scope_id: ctx.scope.id)

      person = person!(ctx, "long.name@example.synthetic.test")
      assert String.length(person.name) == 256
      assert String.starts_with?(person.name, @probe)
      refute Enum.any?(people(ctx), &(to_string(&1.email) == long_email))
    end

    test "content whose scope was shredded after landing writes no person", ctx do
      shred!(ctx, ctx.scope)

      records =
        slack_world(ctx.account, [slack_user("U0NEW", @probe, "new@example.synthetic.test")])

      assert {:ok, %{people: 0, conversations: 0, messages: 0}} =
               Projections.Slack.project(records, ctx.account, erasure_scope_id: ctx.scope.id)

      refute Enum.any?(people(ctx), &(to_string(&1.email) == "new@example.synthetic.test"))
    end
  end

  # --- Gmail ---------------------------------------------------------------------

  describe "Gmail" do
    setup ctx do
      account = link!(ctx, "google-mail")
      {:ok, scope} = Landing.open(account)
      %{account: account, scope: scope}
    end

    test "a sender's over-long display name is clipped, never raised", ctx do
      from = "\"#{@probe} #{String.duplicate("x", 300)}\" <long.sender@example.synthetic.test>"

      sources = [
        gmail(ctx, "m-1", from),
        gmail(ctx, "m-2", "Plain <plain@example.synthetic.test>")
      ]

      assert {:ok, %{messages: 2, failed: 0, people: 2}} =
               Projections.Gmail.project(sources, owner: ctx.user, tenant: ctx.org)

      assert String.length(person!(ctx, "long.sender@example.synthetic.test").name) == 256
    end

    test "a record that cannot be projected is counted and the replay carries on", ctx do
      broken = ctx |> gmail("m-broken", "Broken <broken@example.synthetic.test>") |> drop_date()
      sources = [broken, gmail(ctx, "m-ok", "Fine <fine@example.synthetic.test>")]

      assert {:ok, %{messages: 1, failed: 1}} =
               Projections.Gmail.project(sources, owner: ctx.user, tenant: ctx.org)

      assert [%{body: "SYNTHETIC-SNIPPET-m-ok"}] =
               Message.read!(tenant: ctx.org.id, authorize?: false)
    end

    test "a person is not renamed or linked from another owner's row", ctx do
      sources = [gmail(ctx, "m-1", "\"#{@probe}\" <#{@shared}>")]

      assert {:ok, %{messages: 1, people: 0}} =
               Projections.Gmail.project(sources, owner: ctx.user, tenant: ctx.org)

      assert person!(ctx, @shared).name == "Name From Other Owner"
      assert [%{sender_id: nil}] = Message.read!(tenant: ctx.org.id, authorize?: false)
    end

    test "content whose scope was shredded after landing writes no person", ctx do
      shred!(ctx, ctx.scope)
      sources = [gmail(ctx, "m-1", "\"#{@probe}\" <late@example.synthetic.test>")]

      assert {:ok, %{messages: 0, shredded: 1, people: 0}} =
               Projections.Gmail.project(sources, owner: ctx.user, tenant: ctx.org)

      refute Enum.any?(people(ctx), &(to_string(&1.email) == "late@example.synthetic.test"))
    end
  end

  # --- Calendar ------------------------------------------------------------------

  describe "Calendar" do
    test "content whose scope was shredded after landing writes no person", ctx do
      account = link!(ctx, "google-calendar")
      {:ok, scope} = Landing.open(account)
      shred!(ctx, scope)

      assert {:ok, %{outcome: :shredded, people: []}} =
               Projections.Calendar.project(
                 %{
                   external_system: "google_calendar",
                   external_id: "gcal:synthetic/planning",
                   raw_payload: F.planning_event()
                 },
                 %{owner_id: ctx.user.id, tenant_id: ctx.org.id, erasure_scope_id: scope.id}
               )

      refute Enum.any?(people(ctx), &(to_string(&1.email) == "ada@example.test"))
    end
  end

  # --- helpers ---------------------------------------------------------------------

  defp slack_world(account, users) do
    now = DateTime.utc_now()

    channel = %{
      "id" => "C0GUARDS",
      "name" => "guards-synthetic",
      "is_channel" => true,
      "is_private" => false,
      "is_member" => true
    }

    messages =
      users
      |> Enum.with_index(1)
      |> Enum.map(fn {user, n} ->
        payload = %{
          "type" => "message",
          "user" => user["id"],
          "ts" => "170000000#{n}.000100",
          "text" => "SYNTHETIC-FROM-#{user["id"]}"
        }

        Records.message(account.id, "C0GUARDS", payload, nil, now)
      end)

    [Records.conversation(account.id, channel, now)] ++
      Enum.map(users, &Records.user(account.id, &1, now)) ++ messages
  end

  defp slack_user(id, name, email) do
    %{
      "id" => id,
      "name" => String.downcase(id),
      "real_name" => name,
      "profile" => %{"real_name" => name, "email" => email}
    }
  end

  defp gmail(ctx, id, from) do
    %{
      external_id: "#{ctx.account.id}:#{id}",
      erasure_scope_id: ctx.scope.id,
      source_metadata: %{"stream" => "gmail.messages", "linked_account_id" => ctx.account.id},
      raw_payload: %{
        "id" => id,
        "threadId" => "thread-#{id}",
        "internalDate" => "1791700000000",
        "labelIds" => ["INBOX"],
        "snippet" => "SYNTHETIC-SNIPPET-#{id}",
        "payload" => %{"headers" => [%{"name" => "From", "value" => from}]}
      }
    }
  end

  defp drop_date(source), do: update_in(source.raw_payload, &Map.delete(&1, "internalDate"))

  defp link!(ctx, integration) do
    LinkedAccount.link!(
      %{provider_config_key: integration, connection_id: "conn-#{integration}-#{ctx.unique}"},
      actor: ctx.alice,
      tenant: ctx.org.id
    )
  end

  defp shred!(ctx, scope) do
    Erasure.shred_scope!(scope, scope.ref, "guards test", actor: ctx.alice)
  end

  defp people(ctx), do: Person.read!(tenant: ctx.org.id, authorize?: false)

  defp person!(ctx, email), do: Enum.find(people(ctx), &(to_string(&1.email) == email))

  defp colleague(business_unit, email) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: "password1234", password_confirmation: "password1234"},
      authorize?: false
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(
      :assign_to_business_unit,
      %{owning_business_unit_id: business_unit.id},
      authorize?: false
    )
    |> Ash.update!()
  end

  defp actor(user, org_id),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: org_id))

  defp declare_slack_zone(tmp_dir) do
    today = Date.utc_today()

    declaration = %{
      "id" => "guards-slack-zone",
      "jurisdiction" => "CA-ON",
      "classification_ceiling" => "customer_confidential",
      "inadmissible_restrictions" => ["US"],
      "declared_by" => "Test Operator",
      "declared_at" => Date.to_iso8601(Date.add(today, -1)),
      "review_by" => Date.to_iso8601(Date.add(today, 30))
    }

    path = Path.join(tmp_dir, "guards-slack-zone.json")
    File.write!(path, Jason.encode!(declaration))

    previous_zones = Application.get_env(:ash_enterprise, AshEnterprise.Zones)
    previous_slack = Application.get_env(:ash_enterprise, Projections.Slack)
    previous_gate = Application.get_env(:ash_enterprise, Projections.ZoneAdmission)
    Application.put_env(:ash_enterprise, AshEnterprise.Zones, declarations: [path])
    Application.put_env(:ash_enterprise, Projections.ZoneAdmission, zone: "guards-slack-zone")
    Application.put_env(:ash_enterprise, Projections.Slack, zone_gate: Projections.ZoneAdmission)

    on_exit(fn ->
      restore_env(AshEnterprise.Zones, previous_zones)
      restore_env(Projections.Slack, previous_slack)
      restore_env(Projections.ZoneAdmission, previous_gate)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:ash_enterprise, key)
  defp restore_env(key, value), do: Application.put_env(:ash_enterprise, key, value)
end
