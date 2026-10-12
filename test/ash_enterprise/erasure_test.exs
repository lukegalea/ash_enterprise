defmodule AshEnterprise.ErasureTest do
  @moduledoc """
  Crypto-shredding (ADR 0024, erasure half), tested end to end against the real
  tables: content is sealed under its scope's key on the way in, reads back
  transparently while the scope is live, and after a shred reads back as an
  explicit marker — in the raw landing, in the canonical rows, and in the audit
  events their writes produced — while every row, every structural column and
  the audit hash chain survive.

  Phrased, where it can be, as the thing that must not happen: plaintext at
  rest, plaintext in the audit log, a key shared by two scopes, a shred no one
  can attribute, a shred by someone who holds no grant.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Audit.{Chain, EventLog}
  alias AshEnterprise.Canonical.{CalendarEvent, Conversation, Message, Projection}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.{Crypto, Key, Keyring, Scope, Shredded}
  alias AshEnterprise.Ingestion.{SourceObject, TapWorker}
  alias AshEnterprise.Platform.{Correlation, SystemActor}
  alias AshEnterprise.Repo
  alias AshEnterprise.Security.{ActorContext, Privilege, Role, RolePrivilege, UserRole}

  @opts [authorize?: false]
  @secret "Q3 numbers are confidential: churn 4.1%"

  setup do
    Correlation.start_new()

    org =
      AshEnterprise.Accounts.Organization
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Erasure Test",
          unique_name: "erasure-test-#{System.unique_integer([:positive])}"
        },
        @opts
      )
      |> Ash.create!()

    bu =
      AshEnterprise.Accounts.BusinessUnit
      |> Ash.Changeset.for_create(:create, %{name: "Root"}, authorize?: false, tenant: org.id)
      |> Ash.create!()

    operator = user!("operator", bu, org)
    bystander = user!("bystander", bu, org)
    grant_global!(operator, :write, bu, org)

    %{
      org: org,
      bu: bu,
      operator: actor(operator, org),
      bystander: actor(bystander, org),
      operator_user: operator
    }
  end

  describe "keys: one per scope, never shared" do
    test "every scope gets its own key, and the database refuses a second or a shared one" do
      a = scope!("slack:T-ONE")
      b = scope!("slack:T-TWO")

      key_a = Key.for_scope!(a.id, @opts)
      key_b = Key.for_scope!(b.id, @opts)

      assert key_a.fingerprint != key_b.fingerprint
      assert key_a.wrapped_key != key_b.wrapped_key

      # A second key for the same scope: refused by the unique scope identity.
      assert {:error, %Ash.Error.Invalid{}} = Key.issue(fresh_key_params(a.id), @opts)

      # A third scope handed scope A's key bytes (the reuse bug ADR 0024 names):
      # refused by the unique fingerprint identity, whatever code path tried it.
      c = Repo.insert_all("erasure_scopes", [scope_row("slack:T-THREE")], returning: [:id])
      [%{id: c_id}] = elem(c, 1)
      c_id = Ecto.UUID.load!(c_id)

      kek = Crypto.master_key!()
      {:ok, dek_a} = Crypto.unwrap(key_a.wrapped_key, a.id, kek)

      assert {:error, %Ash.Error.Invalid{}} =
               Key.issue(
                 %{
                   scope_id: c_id,
                   wrapped_key: Crypto.wrap(dek_a, c_id, kek),
                   fingerprint: Crypto.fingerprint(dek_a),
                   master_key_id: Crypto.master_key_id(kek)
                 },
                 @opts
               )
    end

    test "a wrapped key copied onto another scope does not unwrap" do
      a = scope!("gmail:luke-one")
      b = scope!("gmail:luke-two")
      key_a = Key.for_scope!(a.id, @opts)

      assert {:ok, _dek} = Crypto.unwrap(key_a.wrapped_key, a.id, Crypto.master_key!())
      assert :error = Crypto.unwrap(key_a.wrapped_key, b.id, Crypto.master_key!())
    end

    test "a ciphertext whose header is rewritten to another scope fails authentication" do
      a = scope!("slack:T-HEADER-A")
      b = scope!("slack:T-HEADER-B")
      {:ok, sealed} = Keyring.seal(a.id, @secret)

      <<"AEE1", _scope::binary-size(16), rest::binary>> = sealed
      forged = "AEE1" <> Ecto.UUID.dump!(b.id) <> rest

      assert {:ok, @secret} = Keyring.open!(sealed)
      assert_raise ArgumentError, ~r/failed authentication/, fn -> Keyring.open!(forged) end
    end

    test "ensure returns the same scope and key on every call" do
      first = scope!("slack:T-ENSURE")
      again = scope!("slack:T-ENSURE")

      assert first.id == again.id

      assert %{rows: [[1]]} =
               Repo.query!("SELECT count(*) FROM erasure_keys WHERE scope_id = $1::uuid", [
                 Ecto.UUID.dump!(first.id)
               ])
    end

    test "no actor is granted key material, not even a system actor", ctx do
      scope!("slack:T-NOREAD")

      scope = Erasure.scope_by_ref!(:connection, "slack:T-NOREAD", @opts)

      # The key exists; reads narrow rather than raise, so to every actor it
      # simply is not there. Only the Keyring (authorize?: false) reaches it.
      assert {:ok, %Key{}} = Key.for_scope(scope.id, @opts)

      for actor <- [SystemActor.oban(), SystemActor.system(), ctx.operator] do
        assert {:ok, nil} = Key.for_scope(scope.id, actor: actor)
      end
    end
  end

  describe "SourceObject: sealed at rest, readable live, shredded after" do
    test "encrypt -> read -> shred -> unreadable, structure intact", ctx do
      scope = scope!("slack:T-VENDORPM")
      payload = %{"ts" => "1728700000.000100", "text" => @secret, "user" => "U123"}

      landed =
        SourceObject.land_under!(
          scope.id,
          %{
            external_system: "slack",
            external_id: "C1/1728700000.000100",
            raw_payload: payload,
            source_metadata: %{"stream" => "messages"},
            fetched_at: DateTime.utc_now()
          },
          @opts
        )

      # At rest: ciphertext only.
      refute raw_column("ingestion_source_objects", "encrypted_raw_payload", landed.id) =~
               "churn"

      # Live: transparent.
      assert SourceObject.by_external!("slack", "C1/1728700000.000100", @opts).raw_payload ==
               payload

      shred!(scope, ctx)

      after_shred = SourceObject.by_external!("slack", "C1/1728700000.000100", @opts)

      assert %Shredded{erasure_scope_id: scope_id} = after_shred.raw_payload
      assert scope_id == scope.id
      assert Shredded.shredded?(after_shred.raw_payload)

      # Rows and structural facts survive.
      assert after_shred.id == landed.id
      assert after_shred.external_system == "slack"
      assert after_shred.external_id == "C1/1728700000.000100"
      assert after_shred.source_metadata == %{"stream" => "messages"}
      assert after_shred.erasure_scope_id == scope.id
    end

    test "nothing new lands under a shredded scope, and ensure never reopens it", ctx do
      scope = scope!("slack:T-CLOSED")
      shred!(scope, ctx)

      assert {:error, %Ash.Error.Invalid{} = error} =
               SourceObject.land_under(
                 scope.id,
                 %{
                   external_system: "slack",
                   external_id: "late",
                   raw_payload: %{"text" => "arrived after the shred"},
                   fetched_at: DateTime.utc_now()
                 },
                 @opts
               )

      assert Exception.message(error) =~ "has been shredded"

      reopened = scope!("slack:T-CLOSED")
      assert reopened.id == scope.id
      assert reopened.status == :shredded
      assert {:ok, nil} = Key.for_scope(scope.id, @opts)
    end

    # The seal runs while the changeset is built, before the write's
    # transaction. A shred that commits in between must still refuse the row:
    # the in-transaction re-check (FOR SHARE on the scope) is what sees it.
    test "a landing sealed before a shred commits is refused at write time", ctx do
      scope = scope!("slack:T-RACE")

      sealed_early =
        Ash.Changeset.for_create(
          SourceObject,
          :land,
          %{
            erasure_scope_id: scope.id,
            external_system: "slack",
            external_id: "T-RACE/C1/1",
            raw_payload: %{"text" => @secret},
            fetched_at: DateTime.utc_now()
          },
          @opts
        )

      assert sealed_early.valid?

      shred!(scope, ctx)

      assert {:error, %Ash.Error.Invalid{} = error} = Ash.create(sealed_early)
      assert Exception.message(error) =~ "has been shredded"
      assert SourceObject.by_external!("slack", "T-RACE/C1/1", @opts) == nil
    end

    test "landing without a scope is refused rather than stored unsealed" do
      assert {:error, %Ash.Error.Invalid{}} =
               SourceObject.land(
                 %{
                   external_system: "slack",
                   external_id: "unscoped",
                   raw_payload: %{"text" => @secret},
                   fetched_at: DateTime.utc_now()
                 },
                 @opts
               )
    end
  end

  describe "canonical rows and their audit events" do
    test "a projected CalendarEvent shreds with its source's scope", ctx do
      context = [owner: ctx.operator_user, tenant: ctx.org.id]

      assert {:ok, %{records: 3}} =
               TapWorker.perform(%Oban.Job{args: %{"pipeline" => "calendar_dev"}})

      assert {:ok, %{calendar: %{calendar_events: 3}}} = Projection.replay(:calendar, context)

      scope = Erasure.scope_by_ref!(:connection, "pipeline:calendar_dev", @opts)

      events = CalendarEvent |> Ash.read!(authorize?: false, tenant: ctx.org.id)

      assert Enum.map(events, & &1.title) |> Enum.sort() ==
               ["Dentist", "Design review with Alice", "Weekly plan review"]

      assert Enum.all?(events, &(&1.erasure_scope_id == scope.id))

      shred!(scope, ctx)

      shredded = CalendarEvent |> Ash.read!(authorize?: false, tenant: ctx.org.id)
      assert length(shredded) == 3
      assert Enum.all?(shredded, &Shredded.shredded?(&1.title))
      # A nil location stays nil: "there was nothing" is not "it is gone".
      assert Enum.any?(shredded, &is_nil(&1.location))
      assert Enum.all?(shredded, &(is_nil(&1.location) or Shredded.shredded?(&1.location)))
      # Structural columns survive.
      assert Enum.all?(shredded, &match?(%DateTime{}, &1.starts_at))

      # Re-projecting a shredded source is skipped, not crashed and not faked.
      assert {:ok, %{calendar: %{calendar_events: 0, shredded: 3}}} =
               Projection.replay(:calendar, context)

      # And the audit trail of every CalendarEvent write carries no plaintext.
      for event <- shredded do
        assert_audit_unreadable(event.id, ["Dentist", "Design review", "Weekly plan", "War room"])
      end

      # Nor does any other audit event: a derived copy anywhere in the log
      # (a projected Person, a composed brief) fails here, not per record.
      # Person names and addresses are kept out of the log by `sensitive?`.
      assert_no_audit_event_spells([
        "Dentist",
        "Design review",
        "Weekly plan",
        "War room",
        "Dr. Molnar",
        "Alice Chen",
        "alice@example.com"
      ])

      assert_chains_verify(ctx.org.id)
    end

    # The morning brief is derived from CalendarEvent content. It stores the
    # event ids it selected, not the rendered text, so a shred reaches it in
    # the row and in the compose's audit event alike.
    test "a composed morning brief shreds with the calendar it was built from", ctx do
      context = [owner: ctx.operator_user, tenant: ctx.org.id]
      brief_opts = [actor: ctx.operator, tenant: ctx.org.id, authorize?: false]

      assert {:ok, %{records: 3}} =
               TapWorker.perform(%Oban.Job{args: %{"pipeline" => "calendar_dev"}})

      assert {:ok, _} = Projection.replay(:calendar, context)

      brief =
        ~D[2026-10-06]
        |> MorningBrief.start_for_date!(brief_opts)
        |> MorningBrief.compose_brief!(brief_opts)

      assert [_one_event] = brief.event_ids
      assert read_brief!(brief, ctx).draft_text =~ "14:00–15:00  Design review with Alice"

      # Never stored: the row carries ids, not text.
      %{rows: [row]} =
        Repo.query!("SELECT * FROM agent_morning_briefs WHERE id = $1::uuid", [
          Ecto.UUID.dump!(brief.id)
        ])

      refute inspect(row) =~ "Design review"

      scope = Erasure.scope_by_ref!(:connection, "pipeline:calendar_dev", @opts)
      shred!(scope, ctx)

      assert read_brief!(brief, ctx).draft_text ==
               "Morning brief for 2026-10-06\n\n14:00–15:00  [shredded]"

      assert_no_audit_event_spells(["Design review", "Alice"])
      assert_chains_verify(ctx.org.id)
    end

    test "Message and Conversation: content, participants and their audit events", ctx do
      scope = scope!("slack:T-MESSAGES")

      conversation =
        Conversation.upsert_from_source!(
          %{
            subject: "#leadership-private",
            participants: %{"emails" => ["ceo@vendorpm.example"]},
            external_system: "slack",
            external_id: "C-LEAD",
            erasure_scope_id: scope.id
          },
          authorize?: false,
          tenant: ctx.org.id
        )

      message =
        Message.upsert_from_source!(
          %{
            owner_id: ctx.operator_user.id,
            owner_type: :user,
            owning_user_id: ctx.operator_user.id,
            owning_business_unit_id: ctx.bu.id,
            body: @secret,
            sent_at: DateTime.utc_now(),
            direction: :inbound,
            external_system: "slack",
            external_id: "C-LEAD/1728700000.000200",
            conversation_id: conversation.id,
            erasure_scope_id: scope.id
          },
          authorize?: false,
          tenant: ctx.org.id
        )

      assert message.body == @secret
      assert conversation.subject == "#leadership-private"
      refute raw_column("canonical_messages", "encrypted_body", message.id) =~ "churn"

      # Live: the ciphertext in the audit event opens to the plaintext, so the
      # event really does carry the content -- under the scope key.
      [event] = audit_events(message.id)
      # The plaintext argument is sensitive, so the event's `data` records nil.
      assert Map.get(event.data, "body") == nil
      assert {:ok, opened} = event |> sealed_in_event("encrypted_body") |> Keyring.open!()
      assert :erlang.binary_to_term(opened) == @secret

      shred!(scope, ctx)

      message =
        Message.by_external!("slack", "C-LEAD/1728700000.000200",
          authorize?: false,
          tenant: ctx.org.id
        )

      conversation =
        Conversation.by_external!("slack", "C-LEAD", authorize?: false, tenant: ctx.org.id)

      assert Shredded.shredded?(message.body)
      assert Shredded.shredded?(conversation.subject)
      assert Shredded.shredded?(conversation.participants)
      assert message.direction == :inbound
      assert message.conversation_id == conversation.id

      # After: the same ciphertext, unchanged in the immutable log, opens to
      # the marker -- and nothing in the event spells the content.
      assert {:shredded, %Shredded{}} =
               event |> sealed_in_event("encrypted_body") |> Keyring.open!()

      assert_audit_unreadable(message.id, ["churn", "confidential"])
      assert_audit_unreadable(conversation.id, ["leadership", "ceo@vendorpm"])

      assert_chains_verify(ctx.org.id)
    end

    test "the shredded marker renders, encodes and interpolates without crashing" do
      marker = %Shredded{erasure_scope_id: Ash.UUID.generate()}

      assert to_string(marker) == "[shredded]"
      assert "body: #{marker}" == "body: [shredded]"
      assert Phoenix.HTML.Safe.to_iodata(marker) == "[shredded]"
      assert %{"shredded" => true} = marker |> Jason.encode!() |> Jason.decode!()
    end
  end

  describe "the shred action" do
    test "is audited: who, when, why -- and never the key", ctx do
      scope = scope!("slack:T-AUDITED")
      key = Key.for_scope!(scope.id, @opts)

      shredded = shred!(scope, ctx, "left VendorPM")

      assert shredded.status == :shredded
      assert %DateTime{} = shredded.shredded_at
      assert shredded.shred_reason == "left VendorPM"

      events = audit_events(scope.id)
      assert Enum.map(events, & &1.action) |> Enum.sort() == [:open, :shred]

      shred_event = Enum.find(events, &(&1.action == :shred))
      assert shred_event.user_id == ctx.operator_user.id
      assert shred_event.changed_attributes["status"] == "shredded"
      assert shred_event.data["reason"] == "left VendorPM"

      # The key is not audited, so the log never holds what the shred destroyed.
      all =
        Repo.query!(
          "SELECT data::text || changed_attributes::text || metadata::text FROM audit_events"
        ).rows

      blob = all |> List.flatten() |> Enum.join()
      refute blob =~ key.fingerprint
      refute blob =~ Base.encode64(key.wrapped_key)
      assert audit_events(key.id) == []

      assert {:ok, nil} = Key.for_scope(scope.id, @opts)
      assert_chains_verify(nil)
    end

    test "is refused for an actor holding no grant, and for every system actor", ctx do
      scope = scope!("slack:T-GUARDED")

      for actor <- [
            ctx.bystander,
            SystemActor.oban(),
            SystemActor.ai(),
            SystemActor.system(),
            nil
          ] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Erasure.shred_scope(scope, scope.ref, "not mine to erase", actor: actor),
               "#{inspect(actor && Map.get(actor, :name, :user))} must not be able to shred"
      end

      assert %Scope{status: :active} = Erasure.get_scope!(scope.id, @opts)
      assert {:ok, %Key{}} = Key.for_scope(scope.id, @opts)
    end

    test "requires the scope's ref as confirmation, and only shreds once", ctx do
      scope = scope!("slack:T-CONFIRM")

      assert {:error, %Ash.Error.Invalid{}} =
               Erasure.shred_scope(scope, "slack:T-SOMETHING-ELSE", "typo", actor: ctx.operator)

      assert {:ok, %Key{}} = Key.for_scope(scope.id, @opts)

      shredded = shred!(scope, ctx)

      assert {:error, %Ash.Error.Invalid{}} =
               Erasure.shred_scope(shredded, scope.ref, "again", actor: ctx.operator)
    end

    test "a shred reaches only its own scope", ctx do
      gone = scope!("slack:T-GONE")
      kept = scope!("gmail:luke-kept")

      {:ok, sealed_gone} = Keyring.seal(gone.id, "gone")
      {:ok, sealed_kept} = Keyring.seal(kept.id, "kept")

      shred!(gone, ctx)

      assert {:shredded, _} = Keyring.open!(sealed_gone)
      assert {:ok, "kept"} = Keyring.open!(sealed_kept)
    end
  end

  describe "the operator path" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "mix ash_enterprise.erasure.shred runs as the named person, under their grants", ctx do
      scope = scope!("slack:T-MIX")
      task = Mix.Tasks.AshEnterprise.Erasure.Shred

      assert_raise Mix.Error, ~r/no write grant/, fn ->
        task.run([
          "connection:slack:T-MIX",
          "--as",
          to_string(ctx.bystander.email),
          "--reason",
          "not mine",
          "--yes"
        ])
      end

      assert Erasure.get_scope!(scope.id, @opts).status == :active

      task.run([
        "connection:slack:T-MIX",
        "--as",
        to_string(ctx.operator_user.email),
        "--reason",
        "left VendorPM",
        "--yes"
      ])

      assert %Scope{status: :shredded, shred_reason: "left VendorPM"} =
               Erasure.get_scope!(scope.id, @opts)

      assert [shred_event] = scope.id |> audit_events() |> Enum.filter(&(&1.action == :shred))
      assert shred_event.user_id == ctx.operator_user.id
    end

    test "mix ash_enterprise.erasure.scopes lists scopes with their status", ctx do
      scope = scope!("slack:T-LISTED")
      shred!(scope, ctx)

      Mix.Tasks.AshEnterprise.Erasure.Scopes.run([])

      assert_received {:mix_shell, :info, [line]}
      assert line =~ "connection:slack:T-LISTED  shredded "
    end

    test "a missing key under a live scope is a loud failure, never a quiet shred" do
      scope = scope!("slack:T-LOST")
      {:ok, sealed} = Keyring.seal(scope.id, "still here")

      # Out-of-band loss (a restore without the key table, a bad manual edit):
      # the scope is still active, so this must not read as an erasure.
      Repo.query!("DELETE FROM erasure_keys WHERE scope_id = $1::uuid", [
        Ecto.UUID.dump!(scope.id)
      ])

      assert_raise RuntimeError, ~r/lost key, not a shred/, fn -> Keyring.open!(sealed) end
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp scope!(ref) do
    Erasure.ensure_scope!(:connection, ref, %{label: "test #{ref}"}, actor: SystemActor.oban())
  end

  defp shred!(scope, ctx, reason \\ "test shred") do
    Erasure.shred_scope!(scope, scope.ref, reason, actor: ctx.operator)
  end

  defp fresh_key_params(scope_id) do
    kek = Crypto.master_key!()
    dek = Crypto.generate_key()

    %{
      scope_id: scope_id,
      wrapped_key: Crypto.wrap(dek, scope_id, kek),
      fingerprint: Crypto.fingerprint(dek),
      master_key_id: Crypto.master_key_id(kek)
    }
  end

  defp scope_row(ref) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.dump!(Ash.UUID.generate()),
      kind: "connection",
      ref: ref,
      status: "active",
      inserted_at: now,
      updated_at: now,
      created_on: now,
      modified_on: now
    }
  end

  defp raw_column(table, column, id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1::uuid", [Ecto.UUID.dump!(id)])

    value
  end

  defp audit_events(record_id) do
    EventLog
    |> Ash.Query.filter(record_id == ^record_id)
    |> Ash.read!(authorize?: false)
  end

  # The sealed binary as the audit event stores it: ash_cloak's base64 of the
  # sealed bytes, which the event log may encode once more as a binary.
  defp sealed_in_event(event, field) do
    event.changed_attributes
    |> Map.fetch!(field)
    |> unwrap_base64()
  end

  defp unwrap_base64(<<"AEE1", _::binary>> = sealed), do: sealed

  defp unwrap_base64(encoded) when is_binary(encoded) do
    encoded |> Base.decode64!() |> unwrap_base64()
  end

  defp assert_audit_unreadable(record_id, fragments) do
    events = audit_events(record_id)
    assert events != [], "expected audit events for #{record_id}"

    for event <- events do
      text = Jason.encode!(%{d: event.data, c: event.changed_attributes, m: event.metadata})

      for fragment <- fragments do
        refute text =~ fragment, "audit event #{event.id} still spells #{inspect(fragment)}"
      end
    end
  end

  # Every audit event in the (sandboxed) table, not just one record's.
  defp assert_no_audit_event_spells(fragments) do
    for event <- Ash.read!(EventLog, authorize?: false) do
      text = Jason.encode!(%{d: event.data, c: event.changed_attributes, m: event.metadata})

      for fragment <- fragments do
        refute text =~ fragment,
               "audit event #{event.id} (#{event.resource} #{event.action}) still spells " <>
                 inspect(fragment)
      end
    end
  end

  defp read_brief!(brief, ctx) do
    MorningBrief
    |> Ash.Query.filter(id == ^brief.id)
    |> Ash.Query.load(:draft_text)
    |> Ash.read_one!(authorize?: false, tenant: ctx.org.id)
  end

  defp assert_chains_verify(organization_id) do
    assert %{findings: []} = Chain.verify(organization_id)
  end

  defp user!(name, bu, org) do
    AshEnterprise.Accounts.User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "#{name}-#{System.unique_integer([:positive])}@erasure.test",
        password: "password1234",
        password_confirmation: "password1234"
      },
      authorize?: false
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:assign_to_business_unit, %{owning_business_unit_id: bu.id},
      authorize?: false
    )
    |> Ash.update!()
    |> Map.put(:organization_id, org.id)
  end

  defp actor(user, org), do: ActorContext.attach(user, ActorContext.build(user, tenant: org.id))

  defp grant_global!(user, verb, bu, org) do
    privilege =
      Privilege
      |> Ash.Changeset.for_create(
        :create,
        %{
          resource_name: inspect(Scope),
          access_right: verb,
          name: "prv#{verb}ErasureScope#{System.unique_integer([:positive])}"
        },
        authorize?: false
      )
      |> Ash.create!()

    role =
      Role
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "erasure-operator-#{System.unique_integer([:positive])}",
          owning_business_unit_id: bu.id
        },
        authorize?: false,
        tenant: org.id
      )
      |> Ash.create!()

    RolePrivilege
    |> Ash.Changeset.for_create(
      :create,
      %{role_id: role.id, privilege_id: privilege.id, depth: :global},
      authorize?: false,
      tenant: org.id
    )
    |> Ash.create!()

    UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{user_id: user.id, role_id: role.id, scoping_business_unit_id: bu.id},
      authorize?: false,
      tenant: org.id
    )
    |> Ash.create!()
  end
end
