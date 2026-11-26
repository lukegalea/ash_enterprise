defmodule AshEnterprise.Provenance.DemoData do
  @moduledoc """
  The demo tenant's data for asking where a value came from (ADR 0078): a task a person
  captured and planned, two judged facts (one whose cited document has since been erased),
  and a task written by a recipe's steps under a standing grant. Every row is made by the
  application's own actions, so the audit log, the judgment ledger and the dispatch ledger
  hold what a real run leaves.

  Three people read it, each with only what the role grants:

    * `reader_email/0` holds the read grants the answers draw on and sees every hop;
    * `viewer_email/0` holds none, so every address below is not found for them;
    * `publisher_email/0` publishes the recipe (`publish_granted`), so its steps run as the
      `recipe_runner` for them.

  `populate/3` finds each row before it makes it, so running it again changes nothing, and
  returns the handles the scripted check asks about (`scripts/provenance-demo.sh`).

  A band table for the judged question's family is published into the platform organization
  when none is there, the way `AshEnterprise.Mdm.Baselines` publishes the match bands. The
  observations are synthetic recorded answers: no model is called.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Bpmn.Definition, as: ProcessDefinition
  alias AshEnterprise.Bpmn.{Dispatch, Subscription}
  alias AshEnterprise.Bpmn.Subscription.Authority
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.Clinician
  alias AshEnterprise.Decisions.{Definition, Evaluation}
  alias AshEnterprise.Execution.Identity
  alias AshEnterprise.Platform.{DemoData, Seeder, SystemActor}
  alias AshEnterprise.Process.Resolver
  alias AshEnterprise.Security
  alias AshEnterprise.Security.{ActorContext, AgentStartGrant}
  alias AshEnterprise.SystemOne.{Banding, Fact, Judgment, ShowcaseSubject}
  alias AshEnterprise.SystemOne.Banding.Resolver, as: BandResolver
  alias AshEnterprise.SystemOne.Banding.Step
  alias AshJudgments.Registry.Info

  @writer "dana@example.com"
  @reader "provenance-reader@example.com"
  @viewer "provenance-viewer@example.com"
  @publisher "provenance-publisher@example.com"

  @task_title "Send Dana the Q3 deck"
  @recipe_task_title "Follow up the licence"
  @recipe_key "demo.provenance_recipe"
  @fact_subject_type "provenance_demo_clinician"
  @family "showcase_search"

  @band_table """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
               id="band_showcase_search_definitions"
               name="Showcase search band"
               namespace="https://ash-enterprise.example/dmn/band-showcase-search"
               expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
               typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
    <inputData id="input_family" name="family">
      <variable id="var_family" name="family" typeRef="string"/>
    </inputData>
    <decision id="decision_band" name="Band">
      <variable id="var_band" name="Band" typeRef="string"/>
      <informationRequirement id="req_family">
        <requiredInput href="#input_family"/>
      </informationRequirement>
      <decisionTable id="table_band" hitPolicy="UNIQUE">
        <input id="clause_family">
          <inputExpression id="expr_family" typeRef="string"><text>family</text></inputExpression>
        </input>
        <output id="out_band" name="band" typeRef="string"/>
        <rule id="rule_showcase_search"><inputEntry id="ie_family"><text>"showcase_search"</text></inputEntry><outputEntry id="oe_admit"><text>"admit"</text></outputEntry></rule>
      </decisionTable>
    </decision>
  </definitions>
  """

  @recipe """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_provenance_demo" targetNamespace="https://example.com/bpmn">
    <bpmn2:process id="Process_provenance_demo" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:serviceTask id="CheckExpiry" name="Check the licence expiry">
        <bpmn2:extensionElements><ash:taskConfig action="check_licence_expiry"/></bpmn2:extensionElements>
        <bpmn2:incoming>F1</bpmn2:incoming>
        <bpmn2:outgoing>F2</bpmn2:outgoing>
      </bpmn2:serviceTask>
      <bpmn2:endEvent id="End"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F1" sourceRef="Start" targetRef="CheckExpiry"/>
      <bpmn2:sequenceFlow id="F2" sourceRef="CheckExpiry" targetRef="End"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  @readable [
    {Task, :read},
    {EventLog, :read},
    {User, :read},
    {Fact, :read},
    {Banding, :read},
    {Evaluation, :read},
    {Judgment, :read},
    {Dispatch, :read},
    {AgentStartGrant, :read}
  ]

  @doc "The people this seed adds besides the ones `AshEnterprise.Platform.DemoData` makes."
  @spec emails() :: [String.t()]
  def emails, do: [@reader, @viewer, @publisher]

  @doc "The person who reads every hop of every answer."
  @spec reader_email() :: String.t()
  def reader_email, do: @reader

  @doc "The person who holds no read grant at all."
  @spec viewer_email() :: String.t()
  def viewer_email, do: @viewer

  @doc "The person whose recipe's steps write the recipe task."
  @spec publisher_email() :: String.t()
  def publisher_email, do: @publisher

  @doc "The person who captured the task."
  @spec writer_email() :: String.t()
  def writer_email, do: @writer

  @doc "The title of the task a recipe's steps wrote."
  @spec recipe_task_title() :: String.t()
  def recipe_task_title, do: @recipe_task_title

  @doc """
  `email` as an actor in `tenant`, their grants rebuilt from their rows now.
  """
  @spec actor!(String.t(), Ash.UUID.t()) :: ActorContext.actor()
  def actor!(email, tenant) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one!(authorize?: false)
    |> as_person(tenant)
  end

  @doc """
  Fills `tenant` and returns the handles:
  `%{task:, clinician_facts:, recipe_task:, dispatch:, grant:}`, each the row's id (the
  facts as `%{kept:, erased:}`).

  `admin` is the tenant's administrator, whose credential write is what the recipe answers
  (and who is never its authority). `opts` takes `:password`, the one the new people get.
  """
  @spec populate(Ash.UUID.t(), User.t(), keyword()) :: map()
  def populate(tenant, admin, opts \\ []) do
    password = Keyword.get_lazy(opts, :password, &Seeder.default_password!/0)
    people = people!(tenant, password)

    task = task!(people.writer, tenant)
    {dispatch, grant, recipe_task} = recipe!(people.publisher, admin, tenant)

    %{
      task: task.id,
      clinician_facts: facts!(tenant),
      recipe_task: recipe_task.id,
      dispatch: dispatch.id,
      grant: grant.id
    }
  end

  # -- people ---------------------------------------------------------------

  defp people!(tenant, password) do
    actor = SystemActor.seed()
    root = DemoData.root_business_unit!(tenant, actor)

    reader = person!(@reader, "Provenance reader", @readable, root, tenant, password, actor)
    person!(@viewer, nil, [], root, tenant, password, actor)

    publisher =
      person!(
        @publisher,
        "Recipe publisher",
        [{Subscription, :read}, {Subscription, :write}],
        root,
        tenant,
        password,
        actor
      )

    %{writer: actor!(@writer, tenant), reader: reader, publisher: publisher}
  end

  defp person!(email, role_name, rights, root, tenant, password, actor) do
    user = DemoData.ensure_user!(email, root, tenant, password)

    if role_name do
      role =
        DemoData.ensure_role!(
          role_name,
          "Reads where values came from: the grants the explanations draw on.",
          privileges(rights),
          :global,
          root,
          tenant,
          actor
        )

      DemoData.ensure_user_role!(user, role, root, tenant, actor)
    end

    as_person(user, tenant)
  end

  defp privileges(rights) do
    wanted = MapSet.new(rights, fn {resource, right} -> {inspect(resource), right} end)

    Security.Privilege
    |> Ash.read!(actor: SystemActor.seed())
    |> Enum.filter(&MapSet.member?(wanted, {&1.resource_name, &1.access_right}))
  end

  defp as_person(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  # -- the task a person captured and planned ---------------------------------

  defp task!(writer, tenant) do
    opts = [actor: writer, tenant: tenant]

    existing =
      Task
      |> Ash.Query.filter(title == ^@task_title)
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    case existing do
      nil ->
        task = Task.capture!(@task_title, %{}, opts)
        Task.plan_today_mine!(task.id, opts)
        task

      task ->
        task
    end
  end

  # -- judged facts -----------------------------------------------------------

  defp facts!(tenant) do
    publish_band_table!()

    %{
      kept: fact!(tenant, "kept", erase?: false),
      erased: fact!(tenant, "erased", erase?: true)
    }
  end

  defp fact!(tenant, name, erase?: erase?) do
    subject_id = "provenance-demo-#{name}"
    predicate = question().question_id

    existing =
      Fact
      |> Ash.Query.filter(subject_id == ^subject_id and predicate == ^predicate)
      |> Ash.read_one!(tenant: tenant, authorize?: false)

    (existing || band!(tenant, subject_id, erase?)).id
  end

  defp band!(tenant, subject_id, erase?) do
    question = question()
    document = document!(subject_id)

    observation =
      Judgment
      |> Ash.Changeset.for_create(
        :record,
        %{
          id: Ash.UUID.generate(),
          question_id: question.question_id,
          question_hash: question.question_hash,
          question_version: question.version,
          family: @family,
          subject_type: @fact_subject_type,
          subject_id: subject_id,
          state_digest: "sha256:" <> String.duplicate("c", 64),
          answer_kind: :noul,
          probabilities: %{"true" => "0.93", "false" => "0.07"},
          model_spec_requested: "recorded-answer",
          model_version: "recorded-1.0.0",
          model_digest: "sha256:" <> String.duplicate("d", 64),
          runtime_version: "recorded-1.0.0",
          profile: "recorded",
          latency_us: 0,
          mode: :eval,
          atom_ids: document.atom_ids
        },
        actor: SystemActor.process(),
        tenant: tenant
      )
      |> Ash.create!()

    answer = %{
      question: question,
      answer: %{value: true, probabilities: %{"true" => 0.93, "false" => 0.07}},
      observation_id: observation.id
    }

    {:ok, %{banding: banding}} =
      Step.band([answer],
        family: @family,
        tenant: tenant,
        subject: %{"type" => @fact_subject_type, "id" => subject_id},
        predicate: question.question_id,
        risk_tier: "low",
        jurisdiction: "EX-1"
      )

    # The cited document is erased after the fact was admitted: its atoms are gone and the
    # fact's answer says so, where it would otherwise name them.
    if erase?, do: :ok = AshEvidence.Domain.destroy_document_version(document.version_id)

    Fact
    |> Ash.Query.filter(admission_id == ^banding.id)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
  end

  defp question, do: Info.question(ShowcaseSubject, :licence_scan_legible)

  # One synthetic document version with two addressed atoms, through the evidence domain's
  # code interfaces; its bytes carry the subject so each fact cites a document of its own.
  defp document!(subject_id) do
    texts = ["Licence scan #{subject_id}, line 1", "Licence scan #{subject_id}, line 2"]
    bytes = "synthetic bytes: " <> inspect(texts)
    sha256 = "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    {:ok, version} = AshEvidence.Domain.ingest_document("markdown", bytes, sha256)
    parse_run = AshEvidence.Domain.start_parse_run!(version.id, "demo-ingester")

    atom_ids =
      texts
      |> Enum.with_index(1)
      |> Enum.map(fn {text, seq} ->
        AshEvidence.Domain.ingest_atom!(version.id, parse_run.id, seq, text, :line).id
      end)

    AshEvidence.Domain.mark_parse_run_ok!(parse_run)
    %{version_id: version.id, atom_ids: atom_ids}
  end

  # The family's band table, as the platform baseline the banding resolver finds.
  defp publish_band_table! do
    platform = Seeder.seed_platform_organization()
    key = BandResolver.band_table_key(@family)
    opts = [actor: SystemActor.process(), tenant: platform.id]

    unless Definition
           |> Ash.Query.filter(key == ^key and status == :published)
           |> Ash.exists?(tenant: platform.id, authorize?: false) do
      %{key: key, name: key, xml: @band_table}
      |> Definition.create!(opts)
      |> Definition.publish!(opts)

      Resolver.forget_platform_tenant()
    end

    :ok
  end

  # -- the task a recipe's steps wrote ----------------------------------------

  # A recipe published as a standing grant, started by an audited write, then the write a
  # step makes: as the recipe's own actor, under the dispatch and the grant it ran on.
  defp recipe!(publisher, admin, tenant) do
    system = [actor: SystemActor.process(), tenant: tenant]
    subscription = subscription!(publisher, system, tenant)
    dispatch = dispatch!(subscription, admin, tenant)

    grant_key = Authority.grant_key(subscription)

    grant =
      AgentStartGrant
      |> Ash.Query.filter(agent_key == ^grant_key)
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    {:ok, runner} =
      Identity.recipe_actor(publisher.id, grant_key, tenant, %{
        dispatch_id: dispatch.id,
        event_id: dispatch.event_id,
        grant_id: grant.id
      })

    task =
      Task
      |> Ash.Query.filter(title == ^@recipe_task_title)
      |> Ash.read_one!(authorize?: false, tenant: tenant) ||
        Task.capture!(@recipe_task_title, %{}, actor: runner, tenant: tenant, authorize?: false)

    {dispatch, grant, task}
  end

  defp subscription!(publisher, system, tenant) do
    Subscription
    |> Ash.Query.filter(key == ^@recipe_key)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
    |> case do
      nil ->
        definition =
          ProcessDefinition.create!(%{key: @recipe_key, name: @recipe_key, xml: @recipe}, system)

        ProcessDefinition.publish!(definition, system)

        Subscription
        |> Ash.Changeset.for_create(
          :create,
          %{
            key: @recipe_key,
            match_resource: "AshEnterprise.Credentialing.Credential",
            match_action: :record,
            match_action_type: :create,
            process_key: @recipe_key
          },
          system
        )
        |> Ash.create!()
        |> Subscription.publish_granted!(actor: publisher, tenant: tenant)

      subscription ->
        subscription
    end
  end

  # The event the recipe answers: a credential written by the administrator, who caused it
  # and is never the recipe's authority. One dispatch is enough, so a re-run writes nothing.
  defp dispatch!(subscription, admin, tenant) do
    case dispatch(subscription, tenant) do
      nil ->
        clinician = Clinician |> Ash.read!(authorize?: false, tenant: tenant) |> hd()

        Credentialing.record_credential!(
          %{
            kind: :licence,
            number: "DEMO-RN-PROVENANCE",
            expires_on: Date.add(Date.utc_today(), 365),
            clinician_id: clinician.id
          },
          actor: as_person(admin, tenant),
          tenant: tenant
        )

        AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})
        dispatch(subscription, tenant) || raise "the recipe's event started no dispatch"

      dispatch ->
        dispatch
    end
  end

  defp dispatch(subscription, tenant) do
    Dispatch
    |> Ash.Query.filter(subscription_id == ^subscription.id)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end
end
