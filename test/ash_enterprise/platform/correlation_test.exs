defmodule AshEnterprise.Platform.CorrelationTest do
  @moduledoc """
  Correlation ids, and the property they exist for: the several audit rows one
  user action produces must be reconstructable as ONE operation.

  Without this an audit trail records what changed but not what happened
  together, and after the fact a single reorganization is indistinguishable from
  several unrelated edits that occurred close in time.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor

  setup do
    Correlation.start_new()
    %{org: Ash.UUID.generate()}
  end

  defp create_bu(name, org, parent \\ nil) do
    BusinessUnit
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, parent_business_unit_id: parent && parent.id},
      authorize?: false,
      tenant: org,
      actor: SystemActor.seed()
    )
    |> Ash.create!()
  end

  defp events_for(record) do
    AshEnterprise.Audit.EventLog
    |> Ash.Query.filter(record_id == ^record.id)
    |> Ash.read!(authorize?: false)
  end

  describe "stamping" do
    test "every audit event carries the request's correlation id", ctx do
      expected = Correlation.id()
      bu = create_bu("Root", ctx.org)

      [event] = events_for(bu)

      assert event.metadata["correlation_id"] == expected
    end

    test "writes from one operation share an id; a new scope gets a different one", ctx do
      first = create_bu("Root", ctx.org)
      second = create_bu("Child", ctx.org, first)

      [e1] = events_for(first)
      [e2] = events_for(second)

      # Same request scope -> same correlation. This is what makes "show me
      # everything that happened in this operation" a single query.
      assert e1.metadata["correlation_id"] == e2.metadata["correlation_id"]

      Correlation.start_new()
      third = create_bu("Other", ctx.org)
      [e3] = events_for(third)

      refute e3.metadata["correlation_id"] == e1.metadata["correlation_id"]
    end

    test "a system actor's identity is recorded in metadata", ctx do
      bu = create_bu("Root", ctx.org)
      [event] = events_for(bu)

      # A system actor cannot be persisted as a foreign key -- it is a
      # compile-time constant, not a row -- so this IS its attribution. Without
      # it, "the seeder did this" and "we failed to record who did this" would
      # both be a null user_id.
      assert event.user_id == nil
      assert event.metadata["system_actor"] == "seed"
    end
  end

  describe "explicit propagation" do
    test "with_correlation/2 joins work done in another scope", ctx do
      originating = Correlation.id()

      # Simulates handing work to a Task or an Oban job: a new process would
      # otherwise start a fresh correlation and orphan its audit events.
      bu =
        Correlation.with_correlation(originating, fn ->
          create_bu("Root", ctx.org)
        end)

      [event] = events_for(bu)
      assert event.metadata["correlation_id"] == originating
    end

    test "the previous scope is restored afterwards", ctx do
      original = Correlation.id()
      other = Ash.UUID.generate()

      Correlation.with_correlation(other, fn -> :ok end)

      assert Correlation.id() == original
      _ = ctx
    end
  end
end
