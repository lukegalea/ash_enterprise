defmodule AshEnterprise.Mdm.StewardTaskTest do
  @moduledoc """
  A steward-decision task decides its match candidate (ADR 0054, addendum of
  2026-10-17), wherever the person decides it:

    * the task board's Complete (`confirm` / `reject` / `escalate`, as the
      task's step declares) and Approvals' Approve / Reject record the
      verdict on the candidate **as the person**, and the verdict completes
      the task in the same transaction;
    * a delegated task is decided by the person it was delegated to;
    * the steward queue's verdict on a candidate whose task someone else
      holds, or by someone who is not the task's candidate, is refused and
      writes nothing;
    * nobody decides a candidate whose golden they cannot read, from any
      door — an import's goldens are the importer's (`@tag golden_owner:
      :importer`), and a share is what lets a steward decide them.

  The steward is a member holding only the seeded Data Steward role: they
  read and act on the task through candidacy, not a task grant. The
  steward-review process runs as the platform baseline, as in production.

  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Bpmn.{Definition, HumanTask, Instance}
  alias AshEnterprise.Mdm.{ImportBatch, MatchCandidate}
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2ui.{ApprovalsUI, MdmStewardUI, TaskBoardUI}

  @xml File.read!("priv/bpmn/mdm_steward_review.bpmn")

  setup context do
    AshEnterprise.Process.Resolver.forget_platform_tenant()
    on_exit(&AshEnterprise.Process.Resolver.forget_platform_tenant/0)

    platform = Seeder.seed_platform_organization().id
    AshEnterprise.Mdm.Banding.publish_seed_bands!(platform)

    %{key: "mdm.steward_review", name: "MDM steward review", xml: @xml}
    |> Definition.create!(actor: SystemActor.process(), tenant: platform)
    |> Definition.publish!(actor: SystemActor.process(), tenant: platform)

    n = System.unique_integer([:positive])

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(name: "Steward #{n}", unique_name: "steward-#{n}")

    org = organization.id

    # Both stewards exist before the task is created: candidacy is resolved
    # from the role when the task opens.
    steward = data_steward!(org, admin)
    senior = data_steward!(org, admin)

    # By default the steward owns the golden. `@tag golden_owner: :importer`
    # gives it to the admin who ran the import, as an import-created golden is.
    golden_owner = if context[:golden_owner] == :importer, do: admin, else: steward.user

    candidate = review_candidate!(org, admin, golden_owner)
    task = steward_task!(candidate, org)

    %{
      org: org,
      admin: admin,
      importer: refresh(%{user: admin, email: to_string(admin.email), tenant: org}),
      steward: refresh(steward),
      senior: refresh(senior),
      candidate: candidate,
      task: task
    }
  end

  # -- people ---------------------------------------------------------------

  # A user holding only the seeded Data Steward role.
  defp data_steward!(org, admin) do
    email = "steward-#{System.unique_integer([:positive])}@example.test"

    user =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: "password1234", password_confirmation: "password1234"},
        authorize?: false
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(
        :assign_to_business_unit,
        %{owning_business_unit_id: admin.owning_business_unit_id},
        authorize?: false
      )
      |> Ash.update!()

    role =
      Security.Role
      |> Ash.Query.filter(name == ^Seeder.data_steward_role())
      |> Ash.read_one!(actor: SystemActor.seed(), tenant: org)

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{
        user_id: user.id,
        role_id: role.id,
        scoping_business_unit_id: admin.owning_business_unit_id
      },
      actor: SystemActor.seed(),
      tenant: org
    )
    |> Ash.create!()

    %{user: user, email: email, tenant: org}
  end

  # A new request: the context (and its candidate task ids) built afresh.
  defp refresh(%{user: user, tenant: org} = person) do
    Map.put(person, :actor, ActorContext.attach(user, ActorContext.build(user, tenant: org)))
  end

  # -- the review candidate and its task ---------------------------------------

  defp review_candidate!(org, admin, golden_owner) do
    AshEnterprise.Mdm.MatchRuleSet
    |> Ash.Changeset.for_create(:draft, %{
      golden_resource: "AshEnterprise.Canonical.Person",
      rules: [
        %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0},
        %{
          "name" => "name_fuzzy",
          "kind" => "fuzzy",
          "field" => "name",
          "algorithm" => "levenshtein",
          "weight" => 0.5
        }
      ]
    })
    |> Ash.create!(tenant: org, authorize?: false)
    |> Ash.Changeset.for_update(:activate, %{}, tenant: org, actor: admin)
    |> Ash.update!(tenant: org, actor: admin)

    # Person is owner-only: whoever owns the golden can read it.
    AshEnterprise.Canonical.Person
    |> Ash.Changeset.for_create(:upsert_from_source, %{
      name: "Ann Existing",
      email: "ann@x.io",
      owner_id: golden_owner.id,
      owning_business_unit_id: admin.owning_business_unit_id
    })
    |> Ash.create!(tenant: org, authorize?: false)

    {:ok, _record} =
      AshEnterprise.Mdm.Landing.land_row(org, "acme", %{
        "Email" => "ann@x.io",
        "Full Name" => "Ann Existing-Smith"
      })

    mapping = activate_host_mapping!(draft_host_mapping!(org, []), org, admin)

    batch =
      ImportBatch
      |> Ash.Changeset.for_create(:open, %{mapping_id: mapping.id, source_slug: "acme"},
        tenant: org,
        authorize?: false
      )
      |> Ash.create!(tenant: org, authorize?: false)

    {:ok, _job} =
      %{"batch_id" => batch.id, "tenant" => org}
      |> AshEnterprise.Mdm.BatchWorker.new()
      |> Oban.insert()

    Oban.drain_queue(queue: :mdm, with_safety: false)
    Oban.drain_queue(queue: :bpmn, with_safety: false)

    MatchCandidate
    |> Ash.Query.filter(band == ^:review and status == ^:pending)
    |> Ash.read_one!(tenant: org, authorize?: false)
  end

  defp steward_task!(candidate, org) do
    instance =
      Instance
      |> Ash.Query.filter(subject_id == ^candidate.id)
      |> Ash.read_one!(tenant: org, authorize?: false)

    HumanTask
    |> Ash.Query.filter(instance_id == ^instance.id and status == :open)
    |> Ash.read_one!(tenant: org, authorize?: false)
  end

  defp reload(record, org), do: Ash.reload!(record, tenant: org, authorize?: false)

  # An explicit read share of the candidate's golden with `user`.
  defp share_golden!(candidate, user, org) do
    Security.AccessGrant
    |> Ash.Changeset.for_create(:share, %{
      principal_id: user.id,
      principal_type: :user,
      resource_name: inspect(AshEnterprise.Canonical.Person),
      record_id: candidate.golden_id,
      rights_mask: Security.AccessRight.to_mask([:read])
    })
    |> Ash.create!(tenant: org, authorize?: false)
  end

  defp undecided!(ctx) do
    assert reload(ctx.candidate, ctx.org).status == :pending
    assert verdict_value(ctx.candidate, ctx.org) == nil
    assert reload(ctx.task, ctx.org).status in [:open, :claimed]
  end

  defp instance_status(task, org) do
    Instance
    |> Ash.Query.filter(id == ^task.instance_id)
    |> Ash.read_one!(tenant: org, authorize?: false)
    |> Map.fetch!(:status)
  end

  defp verdict_value(candidate, org) do
    case reload(candidate, org).human_verdict_ref do
      %{"verdict_id" => id} ->
        AshEnterprise.SystemOne.HumanVerdict
        |> Ash.Query.filter(id == ^id)
        |> Ash.read_one!(tenant: org, authorize?: false)
        |> Map.fetch!(:human_value)
        |> to_string()

      _none ->
        nil
    end
  end

  # -- the surfaces, as the clicking person ------------------------------------

  defp board(person, action, task, values \\ nil) do
    lane = reload(task, person.tenant).status

    context =
      %{"action" => action, "recordId" => task.id, "component" => "board_#{lane}"}
      |> then(&if(values, do: Map.put(&1, "values", values), else: &1))

    AshA2ui.ActionHandler.handle(TaskBoardUI, %{"name" => "invoke", "context" => context},
      actor: person.actor,
      tenant: person.tenant
    )
  end

  defp approvals(person, action, task) do
    AshA2ui.ActionHandler.handle(
      ApprovalsUI,
      %{
        "name" => "invoke",
        "context" => %{"action" => action, "recordId" => task.id, "component" => "table"}
      },
      actor: person.actor,
      tenant: person.tenant
    )
  end

  defp queue(person, action, candidate) do
    AshA2ui.ActionHandler.handle(
      MdmStewardUI,
      %{
        "name" => "invoke",
        "context" => %{"action" => action, "recordId" => candidate.id, "component" => "table"}
      },
      actor: person.actor,
      tenant: person.tenant
    )
  end

  defp run(person, action, args) do
    HumanTask
    |> Ash.ActionInput.for_action(action, args, actor: person.actor, tenant: person.tenant)
    |> Ash.run_action()
  end

  # -- tests --------------------------------------------------------------------

  test "the steward reads the task through candidacy, with the outcomes its step declares", ctx do
    assert ctx.task.id in ActorContext.for_actor(ctx.steward.actor).task_ids

    assert %{declared_outcomes: ["confirm", "reject", "escalate"]} =
             Ash.get!(HumanTask, ctx.task.id,
               actor: ctx.steward.actor,
               tenant: ctx.org,
               load: [:declared_outcomes]
             )
  end

  test "Complete on the board confirms the match and completes the task, as the steward", ctx do
    assert {:ok, _} = board(ctx.steward, "claim_task", ctx.task)

    assert {:ok, _} =
             board(ctx.steward, "complete_task", ctx.task, %{
               "outcome" => "confirm",
               "comment" => "Same person"
             })

    assert reload(ctx.candidate, ctx.org).status == :confirmed
    assert verdict_value(ctx.candidate, ctx.org) == "match"

    task = reload(ctx.task, ctx.org)
    assert task.status == :completed
    assert task.outcome == "confirm"
    assert task.comment == "Same person"
    assert task.decided_by_id == ctx.steward.user.id
    assert instance_status(ctx.task, ctx.org) == :completed
  end

  test "Approvals' Reject rejects the match: the verdict and the task together", ctx do
    assert {:ok, _} = approvals(ctx.steward, "reject", ctx.task)

    assert reload(ctx.candidate, ctx.org).status == :rejected
    assert verdict_value(ctx.candidate, ctx.org) == "no_match"

    task = reload(ctx.task, ctx.org)
    assert task.status == :completed
    assert task.outcome == "reject"
    assert task.decided_by_id == ctx.steward.user.id
  end

  test "Approvals' Approve confirms the match (not `approved`, which the step does not declare)",
       ctx do
    assert {:ok, _} = approvals(ctx.steward, "approve", ctx.task)

    assert reload(ctx.candidate, ctx.org).status == :confirmed
    assert %{status: :completed, outcome: "confirm"} = reload(ctx.task, ctx.org)
  end

  test "escalate records the steward as unsure and leaves the task with them", ctx do
    assert {:ok, _} = board(ctx.steward, "claim_task", ctx.task)
    assert {:ok, _} = board(ctx.steward, "complete_task", ctx.task, %{"outcome" => "escalate"})

    assert reload(ctx.candidate, ctx.org).status == :pending
    assert verdict_value(ctx.candidate, ctx.org) == "unsure"
    assert %{status: :claimed, assignee_id: id} = reload(ctx.task, ctx.org)
    assert id == ctx.steward.user.id
  end

  test "a delegated steward task is decided by the steward it was delegated to", ctx do
    assert {:ok, _} = board(ctx.steward, "claim_task", ctx.task)

    assert {:ok, _} =
             board(ctx.steward, "delegate_task", ctx.task, %{
               "delegate_to_id" => ctx.senior.user.id
             })

    # Whoever delegated it no longer decides it, by any door.
    assert {:error, %Ash.Error.Forbidden{}} =
             run(ctx.steward, :complete_task, %{record_id: ctx.task.id, outcome: "confirm"})

    assert {:error, _} = queue(ctx.steward, "confirm", ctx.candidate)
    assert reload(ctx.candidate, ctx.org).status == :pending
    assert verdict_value(ctx.candidate, ctx.org) == nil

    # Delegating hands over the task, not the golden: the senior steward reads
    # it through a share, as any steward reading someone else's golden does.
    share_golden!(ctx.candidate, ctx.senior.user, ctx.org)
    senior = refresh(ctx.senior)
    assert ctx.task.id in ActorContext.for_actor(senior.actor).task_ids
    assert {:ok, _} = board(senior, "complete_task", ctx.task, %{"outcome" => "reject"})

    assert reload(ctx.candidate, ctx.org).status == :rejected

    task = reload(ctx.task, ctx.org)
    assert task.status == :completed
    assert task.decided_by_id == senior.user.id
    assert task.delegated_from_id == ctx.steward.user.id
  end

  test "the queue refuses a verdict from someone who may not decide the candidate's task", ctx do
    # Holds the candidate grants, and reads the golden through a share, but is
    # no candidate for the task: the verdict would complete a task that is not
    # theirs, so it is refused whole.
    outsider =
      AshEnterprise.Test.DailyFixtures.member!(
        %{tenant: ctx.org, user: ctx.admin},
        "Candidate writer",
        [
          {MatchCandidate, :read, :global},
          {MatchCandidate, :write, :global},
          {AshEnterprise.SystemOne.HumanVerdict, :create, :global}
        ]
      )

    share_golden!(ctx.candidate, outsider.user, ctx.org)
    outsider = %{outsider | actor: refresh(%{user: outsider.user, tenant: ctx.org}).actor}

    assert {:error, %Ash.Error.Forbidden{}} =
             ctx.candidate
             |> Ash.Changeset.for_update(:reject, %{}, actor: outsider.actor, tenant: ctx.org)
             |> Ash.update()

    assert reload(ctx.candidate, ctx.org).status == :pending
    assert verdict_value(ctx.candidate, ctx.org) == nil
    assert reload(ctx.task, ctx.org).status == :open
  end

  test "the board refuses an outcome the steward step does not declare", ctx do
    assert {:ok, _} = board(ctx.steward, "claim_task", ctx.task)

    assert {:error, %Ash.Error.Invalid{} = error} =
             run(ctx.steward, :complete_task, %{record_id: ctx.task.id, outcome: "approved"})

    assert Exception.message(error) =~ "confirm, reject or escalate"
    assert reload(ctx.candidate, ctx.org).status == :pending
    assert reload(ctx.task, ctx.org).status == :claimed
  end

  # -- who can read the golden --------------------------------------------------

  @tag golden_owner: :importer
  test "a steward who cannot read the golden decides nothing about it, by any door", ctx do
    # The task is theirs (a role candidate), the golden is not (the importer's).
    assert ctx.task.id in ActorContext.for_actor(ctx.steward.actor).task_ids

    assert {:error, reject} = approvals(ctx.steward, "reject", ctx.task)
    assert inspect(reject) =~ "not authorized"
    assert {:error, approve} = approvals(ctx.steward, "approve", ctx.task)
    assert inspect(approve) =~ "not authorized"
    undecided!(ctx)

    assert {:ok, _} = board(ctx.steward, "claim_task", ctx.task)

    for outcome <- ["confirm", "reject", "escalate"] do
      assert {:error, %Ash.Error.Forbidden{}} =
               run(ctx.steward, :complete_task, %{record_id: ctx.task.id, outcome: outcome})
    end

    for verdict <- [:confirm, :reject, :escalate] do
      assert {:error, %Ash.Error.Forbidden{}} =
               ctx.candidate
               |> Ash.Changeset.for_update(verdict, %{},
                 actor: ctx.steward.actor,
                 tenant: ctx.org
               )
               |> Ash.update()
    end

    undecided!(ctx)
  end

  @tag golden_owner: :importer
  test "an importer's golden shared with the steward is theirs to decide", ctx do
    share_golden!(ctx.candidate, ctx.steward.user, ctx.org)
    steward = refresh(ctx.steward)

    assert {:ok, _} = board(steward, "claim_task", ctx.task)
    assert {:ok, _} = board(steward, "complete_task", ctx.task, %{"outcome" => "confirm"})

    assert reload(ctx.candidate, ctx.org).status == :confirmed
    assert %{status: :completed, decided_by_id: id} = reload(ctx.task, ctx.org)
    assert id == ctx.steward.user.id
  end

  @tag golden_owner: :importer
  test "the importer, an Administrator, decides their own import through their role", ctx do
    # The role reads every task, so the context carries no candidacy list.
    assert ActorContext.for_actor(ctx.importer.actor).task_ids == []

    assert {:ok, _} = approvals(ctx.importer, "approve", ctx.task)

    assert reload(ctx.candidate, ctx.org).status == :confirmed
    assert %{status: :completed, outcome: "confirm"} = reload(ctx.task, ctx.org)
  end

  # -- machine-only writes -------------------------------------------------------

  test "the steward's write grant does not reach the machine's own candidate writes", ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             ctx.candidate
             |> Ash.Changeset.for_update(:update, %{status: :superseded},
               actor: ctx.steward.actor,
               tenant: ctx.org
             )
             |> Ash.update()

    assert {:error, %Ash.Error.Forbidden{}} =
             ctx.candidate
             |> Ash.Changeset.for_update(
               :record_verdict_ref,
               %{human_verdict_ref: %{"verdict" => "confirm"}},
               actor: ctx.steward.actor,
               tenant: ctx.org
             )
             |> Ash.update()

    assert %{status: :pending, human_verdict_ref: nil} = reload(ctx.candidate, ctx.org)
  end

  # -- long-lived contexts ---------------------------------------------------------

  test "an ACP session's turn runs with candidacy as it is now, not as the session opened",
       ctx do
    {:ok, session} = AshEnterprise.Acp.SessionStore.create(%{"actor" => ctx.steward.user})
    on_exit(fn -> AshEnterprise.Acp.SessionStore.close(session.session_id) end)

    assert ctx.task.id in ActorContext.for_actor(session.actor).task_ids

    # Decided elsewhere after the session opened.
    assert {:ok, _} = approvals(ctx.steward, "reject", ctx.task)

    {:ok, turn} = AshEnterprise.Acp.SessionStore.append_message(session, :user, "tasks")
    refute ctx.task.id in ActorContext.for_actor(turn.actor).task_ids

    # The stored session keeps the actor it was created with.
    {:ok, stored} = AshEnterprise.Acp.SessionStore.load(session.session_id)
    assert stored.actor == session.actor
  end
end
