defmodule AshEnterprise.FlagsTest do
  @moduledoc """
  Tenant feature flags (ADR 0072): a tenant's `Flag` rows, resolved once into the
  person's `ActorContext`, read by `Flags.enabled?/2` without a query. What must not
  happen comes first: an undeclared, killed or foreign flag on, a flip without a
  grant or by machinery, a target reaching past what it names.

  `test.alpha` and `test.beta` are SYNTHETIC keys declared in config/test.exs.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, actor: 1]

  require Ash.Query

  alias AshEnterprise.Accounts.{BusinessUnit, Team, TeamMembership}
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Flags
  alias AshEnterprise.Flags.{Catalogue, Flag, Targeting}
  alias AshEnterprise.Platform.{AutomationPrincipal, SystemActor}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.LiveUserAuth

  @alpha "test.alpha"
  @beta "test.beta"

  setup do
    admin = tenant!()
    %{admin: admin, alice: member!(admin, "Alice", []), bob: member!(admin, "Bob", [])}
  end

  defp call(who), do: [actor: who.actor, tenant: who.tenant]

  defp turn_on!(admin, key \\ @alpha), do: Flags.set_flag!(key, %{state: :on}, call(admin))

  defp target!(admin, targets, key \\ @alpha),
    do: Flags.set_flag!(key, Map.put(targets, :state, :targeted), call(admin))

  # The person's context as their next request builds it.
  defp fresh(%{user: user}), do: actor(Ash.reload!(user, authorize?: false))

  defp team!(admin, members) do
    team =
      Team
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Pilot #{System.unique_integer([:positive])}",
          team_type: :access,
          owning_business_unit_id: admin.user.owning_business_unit_id
        },
        tenant: admin.tenant,
        authorize?: false
      )
      |> Ash.create!()

    for person <- members do
      TeamMembership
      |> Ash.Changeset.for_create(:create, %{user_id: person.user.id, team_id: team.id},
        tenant: admin.tenant,
        authorize?: false
      )
      |> Ash.create!()
    end

    team
  end

  defp unit!(admin, parent_id) do
    BusinessUnit
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Unit #{System.unique_integer([:positive])}", parent_business_unit_id: parent_id},
      tenant: admin.tenant,
      actor: SystemActor.seed()
    )
    |> Ash.create!()
  end

  defp move!(person, unit) do
    person.user
    |> Ash.Changeset.for_update(:assign_to_business_unit, %{owning_business_unit_id: unit.id},
      authorize?: false
    )
    |> Ash.update!()

    person
  end

  describe "what must not be on" do
    test "an undeclared key is off", %{admin: admin} do
      refute Catalogue.declared?("test.undeclared")
      refute Flags.enabled?(admin.actor, "test.undeclared")

      # Nor can a tenant record a decision for it.
      assert {:error, %Ash.Error.Invalid{}} =
               Flags.set_flag("test.undeclared", %{state: :on}, call(admin))
    end

    test "a key killed by the deployment is off even where a tenant turned it on", ctx do
      turn_on!(ctx.admin)
      turn_on!(ctx.admin, @beta)
      assert Flags.enabled?(fresh(ctx.alice), @alpha)

      previous = Application.get_env(:ash_enterprise, Catalogue)
      on_exit(fn -> Application.put_env(:ash_enterprise, Catalogue, previous) end)

      Application.put_env(
        :ash_enterprise,
        Catalogue,
        Keyword.put(previous, :killed, Catalogue.parse_killed(" test.alpha , "))
      )

      alice = fresh(ctx.alice)
      refute Flags.enabled?(alice, @alpha)
      # Only the killed key.
      assert Flags.enabled?(alice, @beta)
      # The tenant's row is untouched.
      assert Flags.get_flag!(@alpha, call(ctx.admin)).state == :on
    end

    test "a flag turned on in another tenant is off here", ctx do
      other = tenant!()
      turn_on!(other)

      assert Flags.enabled?(fresh(other), @alpha)
      refute Flags.enabled?(fresh(ctx.alice), @alpha)
      refute Flags.enabled?(fresh(ctx.admin), @alpha)
      # And this tenant cannot read the other's row.
      assert {:error, _not_found} = Flags.get_flag(@alpha, call(ctx.admin))
    end

    test "a person without a grant on flags cannot turn one on", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Flags.set_flag(@alpha, %{state: :on}, call(ctx.alice))

      flag = Flags.set_flag!(@alpha, %{state: :off}, call(ctx.admin))

      assert {:error, %Ash.Error.Forbidden{}} =
               Flags.turn_on_flag(flag, actor: ctx.alice.actor, tenant: ctx.admin.tenant)

      refute Flags.enabled?(fresh(ctx.alice), @alpha)
    end

    test "no system actor turns a flag on: writing one is a person's act", ctx do
      for system <- [SystemActor.oban(), SystemActor.seed(), SystemActor.process()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Flags.set_flag(@alpha, %{state: :on}, actor: system, tenant: ctx.admin.tenant)
      end

      flag = Flags.set_flag!(@alpha, %{state: :off}, call(ctx.admin))

      assert {:error, %Ash.Error.Forbidden{}} =
               Flags.turn_on_flag(flag, actor: SystemActor.oban(), tenant: ctx.admin.tenant)
    end

    test "an actor that carries no context sees no flag, and nothing is built for it", ctx do
      turn_on!(ctx.admin)
      refute Flags.enabled?(ctx.alice.user, @alpha)
      refute Flags.enabled?(nil, @alpha)
      refute Flags.enabled?(SystemActor.oban(), @alpha)
    end
  end

  describe "targeting" do
    test "a flag targeted at a team is on for its members and off for everyone else", ctx do
      team = team!(ctx.admin, [ctx.alice])
      target!(ctx.admin, %{team_ids: [team.id]})

      assert Flags.enabled?(fresh(ctx.alice), @alpha)
      refute Flags.enabled?(fresh(ctx.bob), @alpha)
      refute Flags.enabled?(fresh(ctx.admin), @alpha)
      # Only the key targeted.
      refute Flags.enabled?(fresh(ctx.alice), @beta)
    end

    test "a flag targeted at a business unit reaches its subtree and not its parent", ctx do
      root_id = ctx.admin.user.owning_business_unit_id
      division = unit!(ctx.admin, root_id)
      office = unit!(ctx.admin, division.id)
      elsewhere = unit!(ctx.admin, root_id)

      move!(ctx.alice, office)
      move!(ctx.bob, elsewhere)
      in_division = move!(member!(ctx.admin, "Carol", []), division)

      target!(ctx.admin, %{business_unit_ids: [division.id]})

      assert Flags.enabled?(fresh(in_division), @alpha)
      assert Flags.enabled?(fresh(ctx.alice), @alpha)
      refute Flags.enabled?(fresh(ctx.bob), @alpha)
      # The admin sits in the root, the division's parent.
      refute Flags.enabled?(fresh(ctx.admin), @alpha)
    end

    test "a flag targeted at a person is on for them alone", ctx do
      target!(ctx.admin, %{user_ids: [ctx.bob.user.id]})

      assert Flags.enabled?(fresh(ctx.bob), @alpha)
      refute Flags.enabled?(fresh(ctx.alice), @alpha)
    end

    test "a percentage rollout is stable for a user across requests", ctx do
      people = for n <- 1..6, do: member!(ctx.admin, "Person #{n}", [])
      flag = target!(ctx.admin, %{percentage: 50})

      first = Map.new(people, &{&1.user.id, Flags.enabled?(fresh(&1), @alpha)})
      second = Map.new(people, &{&1.user.id, Flags.enabled?(fresh(&1), @alpha)})
      assert first == second

      # Each answer is the person's bucket for the key, which does not move.
      for {user_id, on?} <- first do
        assert on? == Targeting.bucket(@alpha, user_id) < 50
        assert Targeting.bucket(@alpha, user_id) == Targeting.bucket(@alpha, user_id)
      end

      # Nobody at 0, everybody at 100.
      Flags.target_flag!(flag, %{percentage: 0}, call(ctx.admin))
      refute Enum.any?(people, &Flags.enabled?(fresh(&1), @alpha))

      flag = Flags.get_flag!(@alpha, call(ctx.admin))
      Flags.target_flag!(flag, %{percentage: 100}, call(ctx.admin))
      assert Enum.all?(people, &Flags.enabled?(fresh(&1), @alpha))
    end

    test "a percentage outside 0 to 100 is refused", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Flags.set_flag(@alpha, %{state: :targeted, percentage: 101}, call(ctx.admin))
    end
  end

  describe "reading a flag" do
    test "enabled? reads the context and issues no query", ctx do
      turn_on!(ctx.admin)
      alice = fresh(ctx.alice)

      handler = "flags-queries-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:ash_enterprise, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:queried, metadata[:source]})
        end,
        nil
      )

      try do
        for _ <- 1..20 do
          assert Flags.enabled?(alice, @alpha)
          refute Flags.enabled?(alice, @beta)
        end

        assert Flags.enabled?(ActorContext.for_actor(alice), @alpha)
      after
        :telemetry.detach(handler)
      end

      refute_received {:queried, _source}
    end

    test "turning a flag off takes effect at the person's next event", ctx do
      flag = turn_on!(ctx.admin)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_user: ctx.alice.user}
      }

      socket = LiveUserAuth.with_actor_context(socket)
      assert Flags.enabled?(socket.assigns.current_user, @alpha)

      Flags.turn_off_flag!(flag, call(ctx.admin))

      # The event's refresh rebuilds the context, and the flag is gone.
      socket = LiveUserAuth.refresh_actor_context(socket)
      refute Flags.enabled?(socket.assigns.current_user, @alpha)
    end

    test "turning a flag on is recorded in the audit log", ctx do
      flag = Flags.set_flag!(@alpha, %{state: :off}, call(ctx.admin))
      Flags.turn_on_flag!(flag, call(ctx.admin))

      events =
        EventLog
        |> Ash.Query.filter(resource == ^Flag and record_id == ^flag.id)
        |> Ash.read!(actor: SystemActor.process(), tenant: ctx.admin.tenant)

      assert %{user_id: user_id} = Enum.find(events, &(&1.action == :turn_on))
      assert user_id == ctx.admin.user.id
      assert Enum.any?(events, &(&1.action == :set))
    end

    test "an automation principal acting for a person sees that person's flags", ctx do
      team = team!(ctx.admin, [ctx.alice])
      target!(ctx.admin, %{team_ids: [team.id]})

      person = ActorContext.build(ctx.alice.user)
      principal = ActorContext.build_automation(:evidence_admitter, ctx.admin.tenant)

      acting =
        AutomationPrincipal.acting(
          AutomationPrincipal.evidence_admitter(),
          ctx.alice.user.id,
          "flag-test",
          ActorContext.intersect(person, principal)
        )

      assert Flags.enabled?(acting, @alpha)
      # The principal on its own is nobody's, and sees none.
      refute Flags.enabled?(principal, @alpha)
      # Nor does it carry another tenant's person's flags.
      other = tenant!()
      foreign = ActorContext.build_automation(:evidence_admitter, other.tenant)
      refute Flags.enabled?(ActorContext.intersect(person, foreign), @alpha)
    end
  end
end
