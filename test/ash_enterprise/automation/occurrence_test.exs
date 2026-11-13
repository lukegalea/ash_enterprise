defmodule AshEnterprise.Automation.OccurrenceTest do
  @moduledoc """
  Facts that are not audited tenant writes (a user deactivated, a sign-in refused) are
  recorded as `Automation.Occurrence` rows in the audit chain of each organization the
  user belongs to, so a subscription can start a process on them.

  Negatives first: another tenant cannot read, no member can create, an unknown identity
  writes nothing, and a failing or stalled write never changes a refusal or a
  deactivation. The positives are the end to end: a published subscription on
  `Occurrence` starts its process after one sweep.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts
  alias AshEnterprise.Accounts.{Team, TeamMembership, User}
  alias AshEnterprise.Automation
  alias AshEnterprise.Automation.{Occurrence, Occurrences}
  alias AshEnterprise.Bpmn.{Definition, Dispatch, Instance, Subscription}
  alias AshEnterprise.Platform.{Seeder, SystemActor}

  @password "password1234"
  @config AshEnterprise.Automation.Occurrences

  @process_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_occurrence_probe"
                     targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:process id="Process_occurrence_probe" name="Occurrence probe" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:endEvent id="End"><bpmn2:incoming>F1</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F1" sourceRef="Start" targetRef="End"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  setup do
    a = seed("a")
    b = seed("b")

    on_exit(fn -> Application.delete_env(:ash_enterprise, @config) end)

    tasks_before = MapSet.new(Task.Supervisor.children(AshEnterprise.TaskSupervisor))

    %{a: a, b: b, tasks_before: tasks_before}
  end

  defp seed(label) do
    n = System.unique_integer([:positive])

    ctx =
      Seeder.seed_tenant(
        unique_name: "occ-#{label}-#{n}",
        email: "occ-#{label}-#{n}@example.test",
        password: @password
      )

    Map.put(ctx, :tenant, ctx.organization.id)
  end

  defp system_opts(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  defp occurrences(tenant) do
    Occurrence
    |> Ash.Query.for_read(:read)
    |> Ash.read!(system_opts(tenant))
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        event_id: "probe-#{System.unique_integer([:positive])}",
        source: "urn:test:probe",
        type: "probe.happened",
        subject: Ash.UUID.generate(),
        time: DateTime.utc_now(),
        data: %{"reason" => "because"}
      },
      overrides
    )
  end

  defp sign_in(email, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(strategy, :sign_in, %{
      "email" => to_string(email),
      "password" => password
    })
  end

  # Waits for the refusal tasks this test started to finish, by monitor and not by
  # sleeping. A task another module left running under the shared supervisor is not
  # one of them.
  defp await_tasks(%{tasks_before: before}) do
    for pid <- Task.Supervisor.children(AshEnterprise.TaskSupervisor),
        not MapSet.member?(before, pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> flunk("a recording task did not finish")
      end
    end

    :ok
  end

  defp deactivate!(user) do
    user
    |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false)
    |> Ash.update!()
  end

  # `user` also belongs to `other`'s organization, through a team there.
  defp join_team_in!(user, other) do
    [team | _] =
      Team
      |> Ash.Query.for_read(:read)
      |> Ash.read!(system_opts(other.tenant))

    TeamMembership
    |> Ash.Changeset.for_create(:create, %{user_id: user.id, team_id: team.id},
      actor: SystemActor.seed(),
      tenant: other.tenant
    )
    |> Ash.create!()
  end

  defp types(tenant), do: tenant |> occurrences() |> Enum.map(& &1.type)

  describe "who can read and write" do
    test "another tenant cannot read an occurrence", %{a: a, b: b} do
      Automation.record_occurrence!(attrs(), system_opts(a.tenant))
      assert [_one] = occurrences(a.tenant)

      # The other tenant's administrator, in their own tenant (the tenant is the session's,
      # never the caller's), sees nothing of A's, even with a row of their own beside it.
      Automation.record_occurrence!(attrs(), system_opts(b.tenant))

      assert [mine] = Automation.list_occurrences!(actor: b.user, tenant: b.tenant)
      assert mine.organization_id == b.tenant
    end

    test "an administrator of the same tenant reads the tenant's occurrences", %{a: a} do
      Automation.record_occurrence!(attrs(), system_opts(a.tenant))
      assert [_one] = Automation.list_occurrences!(actor: a.user, tenant: a.tenant)
    end

    test "a tenant member, even an administrator, cannot create one", %{a: a} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Automation.record_occurrence(attrs(), actor: a.user, tenant: a.tenant)

      refute Automation.can_record_occurrence?(a.user, attrs(), tenant: a.tenant)
      assert occurrences(a.tenant) == []
    end

    test "no other system actor creates one either", %{a: a} do
      for actor <- [SystemActor.process(), SystemActor.seed(), SystemActor.system()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Automation.record_occurrence(attrs(), actor: actor, tenant: a.tenant)
      end
    end

    test "there is no way to change or remove one", %{a: a} do
      actions = Occurrence |> Ash.Resource.Info.actions() |> Enum.map(&{&1.type, &1.name})
      assert Enum.sort(actions) == [create: :record, read: :read]
      refute Occurrence |> Ash.Resource.Info.attribute(:time) |> is_nil()
      assert occurrences(a.tenant) == []
    end

    test "writing the same fact twice is one row", %{a: a} do
      fixed = attrs()
      Automation.record_occurrence!(fixed, system_opts(a.tenant))
      assert {:error, _} = Automation.record_occurrence(fixed, system_opts(a.tenant))
      assert [_one] = occurrences(a.tenant)
    end
  end

  describe "facts, never secrets" do
    test "nested data, a secret-named key, too many keys and too much data are refused", %{
      a: a
    } do
      for data <- [
            %{"nested" => %{"a" => 1}},
            %{"password" => "x"},
            %{"api_token" => "x"},
            %{"Authorization" => "x"},
            Map.new(1..9, &{"k#{&1}", &1}),
            %{"note" => String.duplicate("x", 2_000)}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Automation.record_occurrence(attrs(%{data: data}), system_opts(a.tenant)),
               "accepted #{inspect(data, limit: 3)}"
      end

      assert occurrences(a.tenant) == []
    end
  end

  describe "a refused sign-in" do
    test "for an unknown identity writes nothing, anywhere", %{a: a, b: b} = ctx do
      assert {:error, _} =
               sign_in("nobody-#{System.unique_integer([:positive])}@example.test", "x")

      await_tasks(ctx)

      assert occurrences(a.tenant) == []
      assert occurrences(b.tenant) == []
    end

    test "for a known user writes one occurrence in each organization they belong to",
         %{
           a: a,
           b: b
         } = ctx do
      join_team_in!(a.user, b)

      assert {:error, _} = sign_in(a.user.email, "wrong-password")
      await_tasks(ctx)

      for tenant <- [a.tenant, b.tenant] do
        assert [row] = occurrences(tenant)
        assert row.type == "user.sign_in_refused"
        assert row.subject == a.user.id
        assert row.data == %{"reason" => "bad_password", "failures" => 1}
      end
    end

    test "records no address, password or token", %{a: a} = ctx do
      assert {:error, _} = sign_in(a.user.email, "wrong-password-xyz")
      await_tasks(ctx)

      [row] = occurrences(a.tenant)
      dumped = inspect(Map.from_struct(row))
      refute dumped =~ "wrong-password-xyz"
      refute dumped =~ to_string(a.user.email)
    end

    test "is typed by reason: locked, then deactivated", %{a: a, b: b} = ctx do
      previous = Application.get_env(:ash_enterprise, Accounts.Lockout)

      Application.put_env(:ash_enterprise, Accounts.Lockout,
        max_attempts: 2,
        window_seconds: 900,
        lockout_seconds: 900
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_enterprise, Accounts.Lockout, previous),
          else: Application.delete_env(:ash_enterprise, Accounts.Lockout)
      end)

      for _ <- 1..2, do: assert({:error, _} = sign_in(a.user.email, "wrong"))
      # Locked now: even the right password is refused, and says so.
      assert {:error, _} = sign_in(a.user.email, @password)
      await_tasks(ctx)

      reasons = a.tenant |> occurrences() |> Enum.map(& &1.data["reason"]) |> Enum.sort()
      assert reasons == ["bad_password", "bad_password", "locked"]

      assert {:error, _} = sign_in(b.user.email, "wrong")
      deactivate!(b.user)
      assert {:error, _} = sign_in(b.user.email, @password)
      await_tasks(ctx)

      assert "deactivated" in Enum.map(occurrences(b.tenant), & &1.data["reason"])
    end

    test "is answered without waiting for its occurrence to be written", %{a: a} = ctx do
      test = self()

      Application.put_env(:ash_enterprise, @config,
        record: fn _write ->
          send(test, {:writing, self()})

          receive do
            :go -> :ok
          end
        end
      )

      # The refusal comes back while the write is still blocked.
      assert {:error, _} = sign_in(a.user.email, "wrong")
      assert_receive {:writing, writer}, 5_000
      assert Process.alive?(writer)

      send(writer, :go)
      await_tasks(ctx)
    end

    test "stays a refusal when the write raises", %{a: a} = ctx do
      Application.put_env(:ash_enterprise, @config, record: fn _write -> raise "boom" end)

      assert {:error, _} = sign_in(a.user.email, "wrong")
      await_tasks(ctx)
      assert {:ok, _} = sign_in(a.user.email, @password)
      assert occurrences(a.tenant) == []
    end

    test "stays a refusal when the task supervisor is not running", %{a: a} do
      Application.put_env(:ash_enterprise, @config, supervisor: :no_such_supervisor)

      assert {:error, _} = sign_in(a.user.email, "wrong")
      assert {:error, _} = sign_in("nobody@example.test", "wrong")
      assert occurrences(a.tenant) == []
    end

    test "does not turn a success into a refusal, and a success writes nothing", %{a: a} = ctx do
      assert {:ok, _} = sign_in(a.user.email, @password)
      await_tasks(ctx)
      assert occurrences(a.tenant) == []
    end
  end

  describe "a deactivation" do
    test "writes one occurrence per organization the user belongs to", %{a: a, b: b} do
      join_team_in!(a.user, b)

      deactivate!(a.user)

      for tenant <- [a.tenant, b.tenant] do
        assert [row] = occurrences(tenant)
        assert row.type == "user.deactivated"
        assert row.subject == a.user.id
        assert row.source == Occurrences.source()
      end
    end

    test "reaches only the organizations the user belongs to", %{a: a, b: b} do
      deactivate!(a.user)

      assert types(a.tenant) == ["user.deactivated"]
      assert types(b.tenant) == []
    end

    test "is written by the platform, not by the deactivated user", %{a: a} do
      deactivate!(a.user)

      assert [row] = occurrences(a.tenant)
      refute row.created_by_id == a.user.id
    end

    test "stands when the write fails", %{a: a} do
      Application.put_env(:ash_enterprise, @config, record: fn _write -> raise "boom" end)

      assert %User{lifecycle_status: :inactive} = deactivate!(a.user)
      assert occurrences(a.tenant) == []
      assert {:error, _} = sign_in(a.user.email, @password)
    end

    test "a user in no organization writes nothing" do
      email = "occ-lone-#{System.unique_integer([:positive])}@example.test"

      lone =
        User
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{email: email, password: @password, password_confirmation: @password},
          authorize?: false
        )
        |> Ash.create!()

      assert Occurrences.organizations_of(lone) == []
      assert %User{} = deactivate!(lone)
    end
  end

  describe "a recipe on an occurrence" do
    defp publish_probe!(tenant, type) do
      opts = [actor: SystemActor.process(), tenant: tenant]

      key = "occurrence_probe_#{System.unique_integer([:positive])}"

      %{key: key, name: key, xml: @process_xml}
      |> Definition.create!(opts)
      |> Definition.publish!(opts)

      %{
        key: "on-#{System.unique_integer([:positive])}",
        match_resource: "AshEnterprise.Automation.Occurrence",
        match_action: :record,
        match_action_type: :create,
        guard_feel: ~s|data.type = "#{type}"|,
        process_key: key
      }
      |> Subscription.create!(opts)
      |> Subscription.publish!(opts)
    end

    defp sweep!(tenant),
      do: AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})

    defp instances(tenant),
      do: Instance |> Ash.Query.for_read(:read) |> Ash.read!(system_opts_process(tenant))

    defp dispatches(tenant),
      do: Dispatch |> Ash.Query.for_read(:read) |> Ash.read!(system_opts_process(tenant))

    defp system_opts_process(tenant), do: [actor: SystemActor.process(), tenant: tenant]

    test "a refused sign-in starts its process after one sweep", %{a: a} = ctx do
      subscription = publish_probe!(a.tenant, "user.sign_in_refused")

      assert {:error, _} = sign_in(a.user.email, "wrong")
      await_tasks(ctx)
      assert instances(a.tenant) == []

      sweep!(a.tenant)

      assert [instance] = instances(a.tenant)
      assert [dispatch] = dispatches(a.tenant)
      assert dispatch.status == :started
      assert dispatch.subscription_id == subscription.id
      assert dispatch.instance_id == instance.id
      assert instance.organization_id == a.tenant

      sweep!(a.tenant)
      assert [_] = instances(a.tenant)
    end

    test "a deactivation starts its process after one sweep", %{a: a} do
      publish_probe!(a.tenant, "user.deactivated")

      deactivate!(a.user)
      assert instances(a.tenant) == []

      sweep!(a.tenant)

      assert [_instance] = instances(a.tenant)
      assert [%{status: :started}] = dispatches(a.tenant)
    end

    test "a guard on one type does not start on another", %{a: a} = ctx do
      publish_probe!(a.tenant, "user.deactivated")

      assert {:error, _} = sign_in(a.user.email, "wrong")
      await_tasks(ctx)
      sweep!(a.tenant)

      assert types(a.tenant) == ["user.sign_in_refused"]
      assert instances(a.tenant) == []
    end

    test "another tenant's subscription does not see this tenant's occurrence",
         %{a: a, b: b} = ctx do
      publish_probe!(b.tenant, "user.sign_in_refused")

      assert {:error, _} = sign_in(a.user.email, "wrong")
      await_tasks(ctx)
      sweep!(b.tenant)

      assert instances(b.tenant) == []
    end
  end
end
