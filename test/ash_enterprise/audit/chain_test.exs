defmodule AshEnterprise.Audit.ChainTest do
  @moduledoc """
  Tamper-evidence, tested the only way it can honestly be tested: by tampering.

  Every assertion here would have passed vacuously before the chain existed —
  "the audit log is append-only" was a property of the *application*, which
  offers only a `:read` action, and said nothing at all about what a `psql`
  connection could do.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Audit.Chain
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Repo

  setup do
    Correlation.start_new()
    %{org: Ash.UUID.generate()}
  end

  defp create_bu(name, org) do
    BusinessUnit
    |> Ash.Changeset.for_create(:create, %{name: name},
      authorize?: false,
      tenant: org,
      actor: SystemActor.seed()
    )
    |> Ash.create!()
  end

  defp events(org) do
    Repo.query!(
      "SELECT sequence, hash, previous_hash, organization_id FROM audit_events " <>
        "WHERE organization_id = $1::uuid ORDER BY sequence",
      [Ecto.UUID.dump!(org)]
    ).rows
  end

  describe "the chain as written" do
    test "every event carries a hash, and the tenant lifted out of its metadata", ctx do
      bu = create_bu("Root", ctx.org)

      assert [[_seq, hash, previous, org]] = events(ctx.org)

      assert is_binary(hash) and byte_size(hash) == 64
      assert Ecto.UUID.cast!(org) == ctx.org
      # First event in this tenant's chain, so nothing precedes it.
      assert is_nil(previous)

      # The column and the metadata are the same fact, which is why the trigger
      # derives one from the other rather than trusting the caller for both.
      event =
        AshEnterprise.Audit.EventLog
        |> Ash.Query.filter(record_id == ^bu.id)
        |> Ash.read_one!(authorize?: false)

      assert event.metadata["organization_id"] == ctx.org
      assert event.organization_id == ctx.org
    end

    test "each event links to the one before it", ctx do
      create_bu("One", ctx.org)
      create_bu("Two", ctx.org)
      create_bu("Three", ctx.org)

      rows = events(ctx.org)
      assert length(rows) == 3

      hashes = Enum.map(rows, fn [_, hash, _, _] -> hash end)
      previouses = Enum.map(rows, fn [_, _, previous, _] -> previous end)

      assert previouses == [nil | Enum.take(hashes, 2)]
      assert Enum.uniq(hashes) == hashes
    end

    test "chains are per tenant, so one tenant's writes do not enter another's", ctx do
      other = Ash.UUID.generate()

      create_bu("Ours", ctx.org)
      create_bu("Theirs", other)
      create_bu("Ours again", ctx.org)

      ours = events(ctx.org)
      theirs = events(other)

      assert length(ours) == 2
      assert length(theirs) == 1

      # The second of ours links to the first of ours -- not to the write that
      # happened between them in another tenant.
      [[_, first_hash, _, _], [_, _, second_previous, _]] = ours
      assert second_previous == first_hash

      [[_, _, their_previous, _]] = theirs
      assert is_nil(their_previous)
    end

    test "verify/1 passes on a chain nobody has touched", ctx do
      create_bu("One", ctx.org)
      create_bu("Two", ctx.org)

      assert %{findings: [], checked: 2} = Chain.verify(ctx.org)
    end
  end

  describe "the trigger prevents" do
    test "UPDATE is refused", ctx do
      create_bu("Root", ctx.org)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!(
          "UPDATE audit_events SET action = 'tampered' WHERE organization_id = $1::uuid",
          [
            Ecto.UUID.dump!(ctx.org)
          ]
        )
      end
    end

    test "DELETE is refused", ctx do
      create_bu("Root", ctx.org)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM audit_events WHERE organization_id = $1::uuid", [
          Ecto.UUID.dump!(ctx.org)
        ])
      end
    end
  end

  describe "the chain detects what the trigger could not prevent" do
    # Dropping the trigger is exactly what an operator with the necessary
    # privileges would do first. These tests do that, on purpose, because a
    # tamper-evidence claim that has never been tested against tampering is not
    # evidence of anything.

    test "an altered row is found", ctx do
      create_bu("One", ctx.org)
      create_bu("Two", ctx.org)
      create_bu("Three", ctx.org)

      without_immutability(fn ->
        Repo.query!(
          "UPDATE audit_events SET action = 'quietly_changed' " <>
            "WHERE organization_id = $1::uuid AND sequence = " <>
            "(SELECT min(sequence) FROM audit_events WHERE organization_id = $1::uuid)",
          [Ecto.UUID.dump!(ctx.org)]
        )
      end)

      assert %{findings: [finding | _]} = Chain.verify(ctx.org)
      assert finding.problem == :altered
    end

    test "a removed row is found, by the gap it leaves", ctx do
      create_bu("One", ctx.org)
      create_bu("Two", ctx.org)
      create_bu("Three", ctx.org)

      without_immutability(fn ->
        Repo.query!(
          "DELETE FROM audit_events WHERE organization_id = $1::uuid AND sequence = " <>
            "(SELECT min(sequence) + 1 FROM audit_events WHERE organization_id = $1::uuid)",
          [Ecto.UUID.dump!(ctx.org)]
        )
      end)

      assert %{findings: findings} = Chain.verify(ctx.org)
      assert Enum.any?(findings, &(&1.problem == :broken_link))
    end

    test "an event forged with the chain trigger disabled is found", ctx do
      create_bu("One", ctx.org)
      create_bu("Two", ctx.org)

      # With the trigger off, nothing computes a hash and nothing derives the
      # tenant -- so a forger has to set `organization_id` by hand to land the
      # row in someone's trail. Which is the realistic attack: not editing an
      # existing event, but adding one that never happened.
      without_chaining(fn ->
        Repo.query!(
          """
          INSERT INTO audit_events
            (id, record_id, version, metadata, data, changed_attributes,
             occurred_at, resource, action, action_type, organization_id)
          VALUES
            (uuid_generate_v7(), $1::uuid, 1, $2::jsonb, '{}'::jsonb, '{}'::jsonb,
             now(), 'Elixir.Forged', 'approve', 'create', $3::uuid)
          """,
          [
            Ecto.UUID.dump!(Ash.UUID.generate()),
            ~s({"organization_id": "#{ctx.org}"}),
            Ecto.UUID.dump!(ctx.org)
          ]
        )
      end)

      assert %{findings: findings, checked: 3} = Chain.verify(ctx.org)
      assert Enum.any?(findings, &(&1.problem == :unchained))
    end
  end

  # Disables the immutability trigger for the duration, then puts it back. This
  # is the escalation the design assumes an attacker can perform; the chain is
  # what survives it.
  defp without_immutability(fun) do
    Repo.query!("ALTER TABLE audit_events DISABLE TRIGGER audit_events_immutable")
    fun.()
  after
    Repo.query!("ALTER TABLE audit_events ENABLE TRIGGER audit_events_immutable")
  end

  defp without_chaining(fun) do
    Repo.query!("ALTER TABLE audit_events DISABLE TRIGGER audit_events_chain")
    fun.()
  after
    Repo.query!("ALTER TABLE audit_events ENABLE TRIGGER audit_events_chain")
  end
end
