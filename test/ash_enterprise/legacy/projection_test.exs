defmodule AshEnterprise.Legacy.ProjectionTest do
  @moduledoc """
  The projection from the legacy estate into a table this application owns.

  `AshEnterprise.Legacy.ReadModelTest` covers the *view*: does a legacy row arrive as the
  platform resource it is declared to be, and does a legacy write reach the topic the surface
  listens on. This covers what happens next — the same row, written into `projected_users`
  through an ordinary Ash action, so that `/app/directory` reads real columns rather than a view.

  Three of these tests exist because of specific mistakes made while building it, and each is
  the kind that passes review:

    * the backfill and the live projector disagreed about `lifecycle_status`, because the upsert
      was duplicated and the state-machine transition was not;
    * asserting a unique email on the projected table would have silently dropped a person;
    * and the notification's `origin` has to be checked, or a projector at `:dual_write` would
      feed its own writes back to itself.

  The `pg_notify` half of the chain is deliberately **not** exercised here. It needs a committed
  transaction and a running listener, and the sandbox gives neither — `ReadModelTest` asserts the
  trigger and the topic wiring instead. What is tested here is everything downstream of the
  notification, entered exactly where the listener enters it.
  """

  use AshEnterprise.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias AshEnterprise.Accounts.ProjectedUser
  alias AshEnterprise.Legacy.Estate
  alias AshEnterprise.Legacy.Projection
  alias AshEnterprise.Platform.SystemActor

  setup do
    seeded =
      case AshEnterprise.Platform.Seeder.seed_legacy_estate() do
        :already_seeded -> raise "the legacy estate should not survive the sandbox transaction"
        seeded -> seeded
      end

    %{seeded: seeded, tenant: Estate.organization_id()}
  end

  defp opts,
    do: [actor: SystemActor.projection(), tenant: Estate.organization_id(), authorize?: false]

  defp legacy_users do
    AshEnterprise.Legacy.User
    |> Ash.Query.for_read(:read, %{}, opts())
    |> Ash.read!(opts())
  end

  defp projected do
    ProjectedUser
    |> Ash.Query.for_read(:read, %{}, opts())
    |> Ash.read!(opts())
  end

  defp backfill do
    for row <- legacy_users(), do: Projection.project_row(row)
  end

  describe "project_row/1" do
    test "projects every legacy row the read model can see" do
      backfill()

      assert length(projected()) == length(legacy_users())
      assert projected() != []
    end

    test "carries the read model's derived id, so both surfaces describe the same row" do
      backfill()

      legacy = Enum.find(legacy_users(), &(&1.login == "awhitfield"))
      row = Enum.find(projected(), &(&1.legacy_id == legacy.legacy_id))

      # Not an incidental equality. It is what lets a person be followed between
      # /app/legacy-users and /app/directory without a lookup table, and it works only because
      # the uuid derivation is deterministic in SQL and in Elixir alike.
      assert row.id == legacy.id
    end

    test "aligns lifecycle_status through the platform's own state machine" do
      # The regression that prompted `project_row/1` to exist. The backfill used to upsert the
      # row and skip the transition, so a suspended legacy user sat in projected_users marked
      # active -- and whether a row was right depended on whether it had been edited since the
      # projector started.
      backfill()

      by_login = Map.new(projected(), &{&1.login, &1})

      assert by_login["awhitfield"].legacy_state == "active"
      assert by_login["awhitfield"].lifecycle_status == :active

      assert by_login["pending.contractor"].legacy_state == "passive"
      assert by_login["pending.contractor"].lifecycle_status == :inactive

      assert by_login["lfeng"].legacy_state == "suspended"
      assert by_login["lfeng"].lifecycle_status == :inactive
    end

    test "does not lose the two users whose emails differ only by case" do
      # `Dana@corp.example` and `dana@corp.example`. A `:ci_string` unique identity on the
      # projected table would consider them one person and refuse the second row -- a *new* loss,
      # introduced by the new model, on top of the defect it inherited. Carrying both and showing
      # the collision is strictly better, and this is the assertion that keeps it that way.
      backfill()

      danas =
        Enum.filter(projected(), &(String.downcase(to_string(&1.email)) == "dana@corp.example"))

      assert length(danas) == 2
      assert Enum.map(danas, & &1.login) |> Enum.sort() == ["dana.k", "dkowalczyk"]
    end

    test "leaves a row the legacy application soft-deleted out of the projection" do
      # `tobrien` carries a `deleted_at`, which maps onto the attribute AshArchival adds, so the
      # read model filters it -- and therefore so does anything projecting from the read model.
      # Worth asserting because the alternative is a table that quietly resurrects deleted people.
      backfill()

      refute "tobrien" in Enum.map(projected(), & &1.login)
      assert "awhitfield" in Enum.map(projected(), & &1.login)
    end

    test "is idempotent: the upsert key is the legacy id" do
      backfill()
      before = projected()

      backfill()
      backfill()

      after_ = projected()

      assert length(after_) == length(before)

      # And it really re-wrote rather than no-oped, which is what makes it a repair and not just
      # a no-op that happens to leave the right number of rows.
      first_before = Enum.min_by(before, & &1.legacy_id)
      first_after = Enum.min_by(after_, & &1.legacy_id)

      assert first_after.id == first_before.id
      assert DateTime.compare(first_after.projected_at, first_before.projected_at) in [:gt, :eq]
    end

    test "projects a row inserted by the legacy application after the backfill ran" do
      backfill()
      counted = length(projected())

      legacy_id = insert_legacy_user!(first_name: "Ngozi", last_name: "Okafor")
      row = Enum.find(legacy_users(), &(&1.legacy_id == legacy_id))

      assert :ok = Projection.project_row(row)

      assert length(projected()) == counted + 1

      new_row = Enum.find(projected(), &(&1.legacy_id == legacy_id))
      assert new_row.full_name == "Ngozi Okafor"
      assert new_row.legacy_state == "active"
    end
  end

  describe "notify/1" do
    test "projects a notification the listener would dispatch" do
      # Entered exactly where AshStrangler.Listener enters it, including the metadata, because
      # that metadata is load-bearing -- see the next test.
      row = Enum.find(legacy_users(), &(&1.login == "awhitfield"))

      assert :ok =
               Projection.notify(%Ash.Notifier.Notification{
                 resource: AshEnterprise.Legacy.User,
                 domain: AshEnterprise.Legacy,
                 action: %Ash.Resource.Actions.Create{name: :legacy_write, primary?: false},
                 data: row,
                 metadata: %{ash_strangler: %{origin: :legacy, legacy_id: row.legacy_id}}
               })

      assert Enum.find(projected(), &(&1.legacy_id == row.legacy_id))
    end

    test "ignores a notification that did not originate in the legacy application" do
      # At `:dual_write` this resource gains write actions, and its own writes produce
      # notifications too. A projector that acted on those would project its own output back into
      # the table it just wrote -- so the guard is checked here, while the phase makes it
      # untestable-by-accident rather than after it starts mattering.
      row = Enum.find(legacy_users(), &(&1.login == "awhitfield"))

      assert :ok =
               Projection.notify(%Ash.Notifier.Notification{
                 resource: AshEnterprise.Legacy.User,
                 domain: AshEnterprise.Legacy,
                 action: %Ash.Resource.Actions.Create{name: :create, primary?: true},
                 data: row,
                 metadata: %{}
               })

      assert projected() == []
    end

    test "a failing projection does not raise, because it would take the listener with it" do
      # The listener holds the only LISTEN connection, so an exception escaping a notifier stops
      # reactivity on every surface, not just this one. `data` here is missing everything the
      # projection needs.
      #
      # The log is captured and asserted rather than merely silenced: "did not raise" alone would
      # also pass if the failure were swallowed without a trace, and a silently-absent row is the
      # failure mode this design most needs to be noisy about.
      log =
        capture_log(fn ->
          assert :ok =
                   Projection.notify(%Ash.Notifier.Notification{
                     resource: AshEnterprise.Legacy.User,
                     domain: AshEnterprise.Legacy,
                     action: %Ash.Resource.Actions.Create{name: :legacy_write, primary?: false},
                     data: %{legacy_id: nil},
                     metadata: %{ash_strangler: %{origin: :legacy, legacy_id: nil}}
                   })
        end)

      assert log =~ "legacy projection failed"
      assert log =~ "no retry"
    end
  end

  describe "the projected table is an ordinary platform resource" do
    test "rows are tenant-scoped and business-owned like anything else here" do
      backfill()

      assert Enum.all?(projected(), &(&1.organization_id == Estate.organization_id()))
      assert Enum.all?(projected(), &(&1.owning_business_unit_id == Estate.business_unit_id()))
    end

    test "the write is audited, which the read model could not be" do
      # The point of the projection, stated as data. `Legacy.User` sets `audit?: false` because
      # the writes worth auditing are invisible to it. Here the write is an Ash action, so it
      # produces an ordinary audit event -- attributed to the projector rather than to a person,
      # because a person did not do it.
      backfill()

      events =
        AshEnterprise.Audit.EventLog
        |> Ash.Query.for_read(:read, %{}, opts())
        |> Ash.Query.do_filter(resource: AshEnterprise.Accounts.ProjectedUser)
        |> Ash.read!(opts())

      assert events != []
      assert Enum.all?(events, &(&1.metadata["system_actor"] == "projection"))
    end
  end

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
