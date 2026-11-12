defmodule AshEnterprise.Accounts.OffboardingTest do
  @moduledoc """
  The `offboarding` pack (q30): when a person is deactivated, a recipe published as a
  standing grant (ADR 0069) revokes the credentials still live for them, records what they
  hold in the organization, and opens a review for an administrator.

  The refusals come first: nothing runs from the drafts a pack installs, a pack's recipe
  cannot be published plainly, another tenant's deactivation and another kind of occurrence
  start nothing, a step refuses an occurrence that is not a deactivation or is not its
  tenant's, a revoked or lapsed grant changes nothing and the run records `no_authority`, and
  a person reactivated before the run is not touched. Then the run itself, published by the
  tenant's administrator: every kind of credential is dead afterwards, the review opens with
  the leaver's holdings, and the leaver is not one of its candidates.

  Role assignments are not ended by the recipe: ending one is a `changes_authority` act that
  no automation principal may take. The review lists them with why they are inert.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 1, colleague!: 2]

  require Ash.Query

  alias AshEnterprise.Accounts.{ApiKey, Offboarding, User}
  alias AshEnterprise.Accounts.Token, as: AuthToken
  alias AshEnterprise.Automation
  alias AshEnterprise.Automation.{Occurrence, Occurrences}

  alias AshEnterprise.Bpmn.{
    Definition,
    Dispatch,
    HumanTask,
    Instance,
    ProcessEvent,
    Subscription,
    TaskCandidate,
    Token
  }

  alias AshEnterprise.Bpmn.Subscription.Authority
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.AgentStartGrant
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution.Authority, as: Grants

  @pack "offboarding"
  @process "accounts.offboard_leaver"
  @recipe "accounts.offboarding.user_deactivated"
  @password "password1234"

  # What the recipe runner holds: it reads occurrences and writes offboardings, nothing more.
  @runner_grants [
    {Occurrence, :read, :global},
    {Offboarding, :read, :global},
    {Offboarding, :create, :global},
    {Offboarding, :write, :global}
  ]

  setup do
    admin = tenant!()
    {:ok, _} = Subscription.install_pack(@pack, actor: admin.actor, tenant: admin.tenant)

    # The leaver is an administrator here, so their role is one the review must list, and
    # they would be a candidate for it were they not excluded.
    leaver = colleague!(admin, admin?: true)

    %{admin: admin, tenant: admin.tenant, leaver: leaver}
  end

  defp unique, do: System.unique_integer([:positive])

  # The pack goes live only this way: a person publishes the process, then the recipe with
  # publish_granted, and the tenant gives the recipe runner a role.
  defp publish!(ctx, person \\ nil) do
    person = person || ctx.admin
    opts = [actor: person.actor, tenant: ctx.tenant]

    [process] = drafts(Definition, @process, ctx.tenant)
    Definition.publish!(process, opts)

    [recipe] = drafts(Subscription, @recipe, ctx.tenant)
    published = Subscription.publish_granted!(recipe, opts)

    Grants.automation_role!(ctx.admin, :recipe_runner, @runner_grants)
    published
  end

  defp drafts(resource, key, tenant) do
    resource
    |> Ash.Query.filter(key == ^key and status == :draft)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp all(resource, tenant), do: Ash.read!(resource, authorize?: false, tenant: tenant)

  # ── credentials ─────────────────────────────────────────────────────────

  defp sign_in!(%{user: user}) do
    {:ok, signed_in} =
      User
      |> AshAuthentication.Info.strategy!(:password)
      |> AshAuthentication.Strategy.action(:sign_in, %{
        "email" => to_string(user.email),
        "password" => @password
      })

    signed_in.__metadata__.token
  end

  defp api_key!(%{user: user}) do
    ApiKey
    |> Ash.Changeset.for_create(
      :issue,
      %{
        user_id: user.id,
        name: "deploy key",
        expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp live_key?(key), do: match?({:ok, %ApiKey{}}, Ash.get(ApiKey, key.id, authorize?: false))

  defp bearer_user(token) do
    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> AshAuthentication.Plug.Helpers.retrieve_from_bearer(:ash_enterprise)

    conn.assigns[:current_user]
  end

  defp revoked?(token) do
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

    {:ok, revoked?} =
      AuthToken
      |> Ash.ActionInput.for_action(:revoked?, %{jti: jti},
        context: %{private: %{ash_authentication?: true}}
      )
      |> Ash.run_action()

    revoked?
  end

  # ── lifecycle ───────────────────────────────────────────────────────────

  defp deactivate!(%{user: user} = person) do
    %{
      person
      | user:
          user |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false) |> Ash.update!()
    }
  end

  defp activate!(%{user: user} = person) do
    %{
      person
      | user: user |> Ash.Changeset.for_update(:activate, %{}, authorize?: false) |> Ash.update!()
    }
  end

  defp occurrence!(tenant, type) do
    assert [occurrence] =
             Occurrence
             |> Ash.Query.filter(type == ^type)
             |> Ash.read!(actor: SystemActor.oban(), tenant: tenant)

    occurrence
  end

  # ── the engine ──────────────────────────────────────────────────────────

  # The sweep as production runs it: the first advance is a job that runs once the instance
  # and its dispatch row have committed together (see `RecipeAuthorityTest`).
  defp sweep!(tenant) do
    inline = Application.get_env(:ash_bpmn, :oban_testing)
    Application.put_env(:ash_bpmn, :oban_testing, nil)

    try do
      AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})
    after
      Application.put_env(:ash_bpmn, :oban_testing, inline)
    end
  end

  # Later advances run inline; a step that fails raises here.
  defp advance! do
    for job <- all_enqueued(worker: AshBpmn.Runtime.AdvanceWorker) do
      perform_job(AshBpmn.Runtime.AdvanceWorker, job.args)
    end
  end

  # The failed step's job again, on the last attempt Oban will make: the engine gives up,
  # and the instance records why. The step ran inline after the start, so its job is the
  # start's, pointed at the token waiting at the step.
  defp advance_last_attempt!(tenant) do
    [token] =
      Token
      |> Ash.Query.filter(status == :active)
      |> Ash.read!(authorize?: false, tenant: tenant)

    for job <- all_enqueued(worker: AshBpmn.Runtime.AdvanceWorker) do
      args = Map.merge(job.args, %{"node_id" => token.node_id, "token_id" => token.id})
      perform_job(AshBpmn.Runtime.AdvanceWorker, args, attempt: 20, max_attempts: 20)
    end
  end

  defp instance!(tenant) do
    assert [%Dispatch{instance_id: id}] =
             Dispatch
             |> Ash.Query.filter(status == :started)
             |> Ash.read!(authorize?: false, tenant: tenant)

    Ash.get!(Instance, id, authorize?: false, tenant: tenant)
  end

  defp offboardings(tenant), do: all(Offboarding, tenant)

  defp open_reviews(tenant) do
    HumanTask
    |> Ash.Query.filter(status == :open)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp invocations(tenant) do
    Invocation
    |> Ash.Query.sort(created_on: :asc)
    |> Ash.read!(actor: SystemActor.oban(), tenant: tenant)
  end

  # A step run straight through its action, as `person`, on occurrence `id`.
  defp open_as(person, tenant, id) do
    Offboarding
    |> Ash.ActionInput.for_action(:open, %{id: id}, actor: person.actor, tenant: tenant)
    |> Ash.run_action()
  end

  describe "refused" do
    test "nothing runs from the drafts a pack installs", ctx do
      key = api_key!(ctx.leaver)
      deactivate!(ctx.leaver)
      sweep!(ctx.tenant)

      assert all(Dispatch, ctx.tenant) == []
      assert all(Instance, ctx.tenant) == []
      assert offboardings(ctx.tenant) == []
      assert live_key?(key)
    end

    test "the pack's recipe cannot be published plainly: its steps act, and a person grants that",
         ctx do
      [process] = drafts(Definition, @process, ctx.tenant)
      Definition.publish!(process, actor: ctx.admin.actor, tenant: ctx.tenant)
      [recipe] = drafts(Subscription, @recipe, ctx.tenant)

      assert recipe.authority == :human_tasks_only

      assert {:error, _} =
               Subscription.publish(recipe, actor: ctx.admin.actor, tenant: ctx.tenant)

      for system <- [SystemActor.process(), SystemActor.seed(), SystemActor.oban()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Subscription.publish_granted(recipe, actor: system, tenant: ctx.tenant)
      end

      assert Ash.reload!(recipe, authorize?: false).status == :draft
      assert all(AgentStartGrant, ctx.tenant) == []
    end

    test "another tenant's deactivation starts nothing here, and touches nothing there", ctx do
      publish!(ctx)

      other = tenant!()
      outsider = colleague!(other)
      key = api_key!(outsider)
      deactivate!(outsider)

      sweep!(ctx.tenant)
      sweep!(other.tenant)

      assert all(Dispatch, ctx.tenant) == []
      assert all(Dispatch, other.tenant) == []
      assert offboardings(ctx.tenant) == []
      assert offboardings(other.tenant) == []
      assert live_key?(key)
    end

    test "another kind of occurrence starts nothing", ctx do
      publish!(ctx)

      Automation.record_occurrence!(
        %{
          source: Occurrences.source(),
          event_id: "#{Occurrences.sign_in_refused()}:#{unique()}",
          type: Occurrences.sign_in_refused(),
          subject: ctx.leaver.user.id,
          time: DateTime.utc_now(),
          data: %{"reason" => "bad_password"}
        },
        actor: SystemActor.oban(),
        tenant: ctx.tenant
      )

      sweep!(ctx.tenant)
      assert all(Dispatch, ctx.tenant) == []
    end

    test "a step refuses an occurrence that is not a deactivation, and another tenant's", ctx do
      refused =
        Automation.record_occurrence!(
          %{
            source: Occurrences.source(),
            event_id: "#{Occurrences.sign_in_refused()}:#{unique()}",
            type: Occurrences.sign_in_refused(),
            subject: ctx.leaver.user.id,
            time: DateTime.utc_now(),
            data: %{"reason" => "bad_password"}
          },
          actor: SystemActor.oban(),
          tenant: ctx.tenant
        )

      assert {:error, error} = open_as(ctx.admin, ctx.tenant, refused.id)
      assert Exception.message(error) =~ "not_a_deactivation"

      # A deactivation recorded in another tenant is not found from this one.
      other = tenant!()
      deactivate!(colleague!(other))
      elsewhere = occurrence!(other.tenant, Occurrences.deactivated())

      assert {:error, error} = open_as(ctx.admin, ctx.tenant, elsewhere.id)
      assert Exception.message(error) =~ "not_a_deactivation"

      assert offboardings(ctx.tenant) == []
      assert offboardings(other.tenant) == []
    end

    for {how, change} <- [
          revoked: :revoke,
          lapsed: :lapse
        ] do
      test "under a #{how} grant the run records no_authority and changes nothing", ctx do
        recipe = publish!(ctx)

        grant =
          AgentStartGrant
          |> Ash.Query.filter(agent_key == ^Authority.grant_key(recipe))
          |> Ash.read_one!(authorize?: false, tenant: ctx.tenant)

        case unquote(change) do
          :revoke ->
            Ash.destroy!(grant, authorize?: false, tenant: ctx.tenant)

          :lapse ->
            Ash.Seed.update!(grant, %{valid_until: DateTime.add(DateTime.utc_now(), -1, :second)})
        end

        key = api_key!(ctx.leaver)
        deactivate!(ctx.leaver)
        sweep!(ctx.tenant)

        assert_raise RuntimeError, ~r/\{:no_authority, :no_start_grant\}/, &advance!/0

        # On the last attempt the engine gives up, and the instance says why.
        advance_last_attempt!(ctx.tenant)
        instance = instance!(ctx.tenant)
        assert instance.status == :failed

        assert [%{node_id: "Open", data: %{"error" => error}}] =
                 ProcessEvent
                 |> Ash.Query.filter(instance_id == ^instance.id and kind == :action_failed)
                 |> Ash.read!(authorize?: false, tenant: ctx.tenant)

        assert error =~ "no_authority"
        assert error =~ "no_start_grant"

        assert invocations(ctx.tenant) == []
        assert offboardings(ctx.tenant) == []
        assert open_reviews(ctx.tenant) == []
        assert live_key?(key)
      end
    end

    test "a person reactivated before the run is not touched", ctx do
      publish!(ctx)

      key = api_key!(ctx.leaver)
      leaver = ctx.leaver |> deactivate!() |> activate!()

      # Signed in again after the reactivation: a session the run must not end.
      token = sign_in!(leaver)

      sweep!(ctx.tenant)
      advance!()

      assert [%Offboarding{leaver_state: :reactivated} = offboarding] = offboardings(ctx.tenant)
      assert offboarding.sessions_revoked == 0
      assert offboarding.api_keys_revoked == 0
      assert offboarding.revoked_at == nil

      assert live_key?(key)
      assert bearer_user(token).id == leaver.user.id
      refute revoked?(token)

      assert open_reviews(ctx.tenant) == []
      assert Ash.reload!(instance!(ctx.tenant), authorize?: false).outcome == "reactivated"
    end
  end

  describe "published by the administrator" do
    test "deactivation revokes every live credential, and the review opens with the holdings",
         ctx do
      %{admin: admin, tenant: tenant} = ctx
      publish!(ctx)

      # A bystander in the same tenant, whose credentials nothing may touch.
      bystander = colleague!(admin)
      bystander_key = api_key!(bystander)
      bystander_token = sign_in!(bystander)

      # What the leaver holds: a session, an API key, a record they own, their role here.
      session = sign_in!(ctx.leaver)
      key = api_key!(ctx.leaver)
      DailyFixtures.event!(%{user: ctx.leaver.user, tenant: tenant}, "Handover call", 60, 30)

      leaver = deactivate!(ctx.leaver)

      # A token stored after the deactivation's own revocation, as a racing sign-in could:
      # still live until the run revokes it.
      {:ok, straggler, _claims} = AshAuthentication.Jwt.token_for_user(leaver.user)
      refute revoked?(straggler)

      sweep!(tenant)
      advance!()

      # Each kind of credential, one by one.
      assert bearer_user(session) == nil
      assert revoked?(session), "the session token is revoked"
      assert revoked?(straggler), "a token stored after the deactivation is revoked"
      refute live_key?(key), "the API key is archived"

      assert [%Offboarding{} = offboarding] = offboardings(tenant)
      assert offboarding.leaver_id == leaver.user.id
      assert offboarding.leaver_state == :inactive
      assert offboarding.sessions_revoked == 1
      assert offboarding.api_keys_revoked == 1
      assert offboarding.revoked_at

      # The steps ran as the recipe runner acting for the administrator who published it.
      assert [_open, _revoke] = steps = invocations(tenant)
      assert Enum.all?(steps, &(&1.status == :succeeded))

      # The holdings, for the review: the record they own, their role assignment, and why
      # what stays cannot act.
      holdings = offboarding.holdings
      assert holdings["owned_records"]["AshEnterprise.Canonical.CalendarEvent"] == 1
      assert holdings["role_assignments"] == 1
      assert holdings["open_tasks"] == 0
      assert holdings["recipes_accountable"] == []
      assert holdings["inert_because"] =~ "inactive"

      # The review is open, for an administrator who is not the leaver.
      assert [review] = open_reviews(tenant)
      assert review.name == "Review what the leaver held"
      assert review.instance_id == instance!(tenant).id
      assert instance!(tenant).subject_id == offboarding.occurrence_id

      candidates =
        TaskCandidate
        |> Ash.Query.filter(task_id == ^review.id)
        |> Ash.read!(authorize?: false, tenant: tenant)
        |> Enum.map(& &1.principal_id)

      assert admin.user.id in candidates
      refute leaver.user.id in candidates

      # The bystander is untouched.
      assert live_key?(bystander_key)
      assert bearer_user(bystander_token).id == bystander.user.id
    end
  end
end
