defmodule AshEnterprise.Artifacts.RegistryTest do
  @moduledoc """
  The artifact registry (`AshEnterprise.Artifacts`): every versioned resource is
  registered and diffs by meaning; one entry is all a type needs for discovery, a header,
  a diff and validation; a release manifest's diff names authority, tools, models and
  routing; a draft never passes for the version a run used; and nothing that could not be
  compared, read or checked is ever reported as unchanged or valid.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Artifacts
  alias AshEnterprise.Artifacts.{Artifact, Change}
  alias AshEnterprise.Assistant.{Composer, PinnedApp}
  alias AshEnterprise.Execution.{AgentVersion, ReleaseManifest, Run}
  alias AshEnterprise.Quality
  alias AshEnterprise.Test.AssistantFixtures

  @n2 [
    AshEnterprise.Execution.AgentVersion,
    AshEnterprise.Bpmn.Definition,
    AshEnterprise.Decisions.Definition,
    AshEnterprise.Mdm.Mapping,
    AshEnterprise.Quality.Suite,
    AshEnterprise.Execution.ReleaseManifest,
    AshCompliance.Resources.RuleSetRevision,
    AshEnterprise.Assistant.PinnedApp
  ]

  defp entry(type), do: Artifacts.fetch(type)

  defp tool(target, digest), do: %{"target" => target, "target_digest" => digest}

  defp agent(attrs) do
    struct(
      AgentVersion,
      Map.merge(
        %{
          key: "clinic.triager",
          version: 1,
          instructions: "Read the referral.",
          model_profile: "in_zone",
          toolset: [tool("Clinic.Referral.read", "d1")],
          limits: %{max_steps: 4},
          output_type: "string",
          authority: %{type: :requester},
          requesterless: false
        },
        attrs
      )
    )
  end

  # Two versions of each type, differing in something each differ compares.
  defp pair(:agent),
    do: {agent(%{}), agent(%{version: 2, toolset: [tool("Clinic.Referral.route", "d2")]})}

  defp pair(:process) do
    graph = fn condition ->
      %{
        "start" => "S",
        "nodes" => %{"S" => %{"type" => "startEvent"}, "E" => %{"type" => "endEvent"}},
        "flows" => %{"F" => %{"from" => "S", "to" => "E", "condition" => condition}}
      }
    end

    {struct(AshEnterprise.Bpmn.Definition, key: "intake", version: 1, graph: graph.(nil)),
     struct(AshEnterprise.Bpmn.Definition, key: "intake", version: 2, graph: graph.("urgent"))}
  end

  defp pair(:decision) do
    graph = fn output ->
      %{
        "input_data" => %{},
        "decisions" => %{
          "D" => %{
            "name" => "Triage",
            "logic" => "decisionTable",
            "hit_policy" => "FIRST",
            "inputs" => [%{"id" => "I", "expression" => "age"}],
            "outputs" => [%{"id" => "O", "name" => "band"}],
            "rules" => [%{"id" => "R", "input_entries" => ["> 65"], "output_entries" => [output]}]
          }
        }
      }
    end

    {struct(AshEnterprise.Decisions.Definition,
       key: "triage",
       version: 1,
       graph: graph.("\"high\"")
     ),
     struct(AshEnterprise.Decisions.Definition,
       key: "triage",
       version: 2,
       graph: graph.("\"low\"")
     )}
  end

  defp pair(:mapping) do
    mapping = fn rules ->
      struct(AshEnterprise.Mdm.Mapping,
        direction: :ingress,
        source: "clinic_csv",
        stream: "patients",
        target_resource: "Patient",
        version: 1,
        field_rules: rules
      )
    end

    {mapping.([%{"path" => "Email", "target" => "email", "op" => "trim"}]),
     mapping.([%{"path" => "Email Address", "target" => "email", "op" => "trim"}])}
  end

  defp pair(:suite) do
    suite = fn cases ->
      struct(Quality.Suite, key: "triage", version: 1, cases: cases, thresholds: %{})
    end

    {suite.([%{id: "one", input: "SYNTHETIC: one"}]),
     suite.([%{id: "one", input: "SYNTHETIC: one"}, %{id: "two", input: "SYNTHETIC: two"}])}
  end

  defp pair(:release) do
    manifest = fn version ->
      struct(ReleaseManifest,
        key: "clinic",
        version: version,
        entries: [entry_for("process", "intake", "p#{version}", version)]
      )
    end

    {manifest.(1), manifest.(2)}
  end

  defp pair(:rule_set) do
    revision = fn severity ->
      bundle = %{
        "combining" => "deny_overrides",
        "fact_schema" => %{},
        "rules" => [%{"id" => "licence", "name" => "Licence on file", "severity" => severity}]
      }

      struct(AshCompliance.Resources.RuleSetRevision,
        name: "clinic",
        revision: "1",
        layer: :tenant_supplement,
        rules_json: Jason.encode!(bundle)
      )
    end

    {revision.("low"), revision.("high")}
  end

  defp pair(:surface) do
    pin = fn display ->
      {:ok, composed} = Composer.compose(%{show: "tasks", display: display})

      struct(PinnedApp,
        title: Composer.structural_title(composed.request),
        spec: AshA2ui.Dynamic.serialize(composed.surface)
      )
    end

    {pin.("table"), pin.("board")}
  end

  defp entry_for(kind, name, digest, version, id \\ nil) do
    %{
      "name" => name,
      "uri" => "urn:ash-enterprise:#{kind}:#{name}:#{version}",
      "digest" => %{"sha256" => digest},
      "annotations" => %{"kind" => kind, "id" => id, "version" => version}
    }
  end

  describe "the registry" do
    test "every versioned resource N2 names is registered, once" do
      assert Enum.sort(Enum.map(Artifacts.all(), & &1.resource)) == Enum.sort(@n2)
      assert length(Enum.uniq_by(Artifacts.all(), & &1.type)) == length(Artifacts.all())
    end

    test "every attribute an entry names exists on its resource" do
      for %Artifact{resource: resource} = entry <- Artifacts.all() do
        named =
          [entry.identity, entry.version, entry.content_hash, entry.parent] ++
            Keyword.values(entry.lineage || []) ++
            List.wrap(entry.lifecycle && elem(entry.lifecycle, 0))

        for attribute <- Enum.reject(named, &is_nil/1) do
          assert Ash.Resource.Info.attribute(resource, attribute),
                 "#{inspect(resource)} has no #{attribute}"
        end

        if entry.runs do
          {runs, attribute} = entry.runs
          assert Ash.Resource.Info.attribute(runs, attribute)
        end

        for action <- entry.published, do: assert(Ash.Resource.Info.action(resource, action))
      end
    end

    test "every lifecycle state a resource allows is classed, so none falls to unknown" do
      for %Artifact{lifecycle: {attribute, classes}, resource: resource} <- Artifacts.all() do
        states =
          case Ash.Resource.Info.attribute(resource, attribute).constraints[:one_of] do
            nil -> AshStateMachine.Info.state_machine_all_states(resource)
            states -> states
          end

        assert Enum.sort(states) == Enum.sort(Map.keys(classes)), inspect(resource)
        assert Enum.all?(Map.values(classes), &(&1 in [:draft, :current, :past]))
      end
    end

    test "every type diffs, by the aspects its differ says it compares" do
      for %Artifact{type: type, differ: differ} = entry <- Artifacts.all() do
        assert differ, "#{type} has no differ"
        {old, new} = pair(type)

        assert {:changes, [_ | _] = changes} = Artifacts.diff(entry, old, new, []),
               "#{type} found no change"

        aspects = Keyword.keys(differ.aspects())
        assert Enum.all?(changes, &(&1.aspect in aspects)), inspect({type, changes})
      end
    end

    test "a process diff compares the graph's routing, not the XML" do
      {old, new} = pair(:process)
      old = %{old | xml: "<bpmn2:definitions/>"}
      new = %{new | xml: "<bpmn2:definitions>  </bpmn2:definitions>"}

      assert {:changes, [%Change{aspect: :routing, subject: "F", option: "condition"}]} =
               Artifacts.diff(entry(:process), old, new, [])

      assert {:unchanged, :compared} =
               Artifacts.diff(entry(:process), old, %{old | xml: "<moved-shapes/>"}, [])
    end
  end

  describe "a release manifest's diff (UX-14)" do
    setup do
      admin = AssistantFixtures.tenant!()

      seed = fn version, attrs ->
        Ash.Seed.seed!(
          AgentVersion,
          Map.merge(
            %{
              organization_id: admin.tenant,
              key: "clinic.triager",
              version: version,
              source: :code,
              instructions: "Read the referral.",
              model_profile: "in_zone",
              toolset: [tool("Clinic.Referral.read", "d1")],
              limits: %{max_steps: 4},
              output_type: "string",
              content_hash: "h#{version}",
              status: :published,
              authority: %{type: :requester}
            },
            attrs
          )
        )
      end

      v1 = seed.(1, %{})

      v2 =
        seed.(2, %{
          model_profile: "in_zone_large",
          toolset: [tool("Clinic.Referral.read", "d1"), tool("Clinic.Referral.route", "d2")],
          authority: %{type: :automation, name: "triage_bot"}
        })

      %{admin: admin, v1: v1, v2: v2}
    end

    defp manifest(version, agent, process_digest) do
      struct(ReleaseManifest,
        key: "clinic",
        version: version,
        manifest_digest: "m#{version}",
        entries: [
          entry_for("agent", "clinic.triager", agent.content_hash, agent.version, agent.id),
          entry_for("process", "intake", process_digest, version),
          entry_for("model_profile", "in_zone", "z1", nil)
        ]
      )
    end

    test "names changed authority, tools, models and routing rather than text", ctx do
      old = manifest(1, ctx.v1, "p1")
      new = manifest(2, ctx.v2, "p2")

      assert {:changes, changes} =
               Artifacts.diff(entry(:release), old, new,
                 actor: ctx.admin.actor,
                 tenant: ctx.admin.tenant
               )

      by_aspect = Enum.group_by(changes, & &1.aspect)

      assert [%Change{subject: "clinic.triager", from: "requester", to: "automation:triage_bot"}] =
               by_aspect.authority

      assert [%Change{kind: :added, subject: "clinic.triager: Clinic.Referral.route"}] =
               by_aspect.tools

      assert [%Change{subject: "clinic.triager", from: "in_zone", to: "in_zone_large"}] =
               by_aspect.models

      assert Enum.any?(by_aspect.routing, &(&1.subject == "process intake"))

      assert Enum.any?(
               by_aspect.agents,
               &(&1.subject == "clinic.triager" and &1.option == "version")
             )

      # Never the text: no change carries the prompt, the XML or a whole entry.
      refute Map.has_key?(by_aspect, :instructions)
      refute Enum.any?(changes, &(is_binary(&1.from) and &1.from =~ "Read the referral"))
    end

    test "an agent whose versions cannot be read is changed with its contents unread, never unchanged",
         ctx do
      other = AssistantFixtures.tenant!()
      old = manifest(1, ctx.v1, "p1")
      new = manifest(2, ctx.v2, "p1")

      assert {:changes, changes} =
               Artifacts.diff(entry(:release), old, new, actor: other.actor, tenant: other.tenant)

      assert %Change{aspect: :agents, option: "contents", from: :unread, to: :unread} =
               Enum.find(changes, &(&1.option == "contents"))

      refute Enum.any?(changes, &(&1.aspect == :authority))
    end
  end

  describe "registering Suite alone" do
    setup do
      admin = AssistantFixtures.tenant!()
      opts = [actor: admin.actor, tenant: admin.tenant]
      one = %{id: "one", input: "SYNTHETIC: the referral names no clinician"}
      two = %{id: "two", input: "SYNTHETIC: the referral is urgent"}

      v1 =
        "clinic.triage"
        |> Quality.create_suite_draft!(%{cases: [one]}, opts)
        |> Quality.publish_suite!(opts)

      v2 = Quality.create_suite_draft!("clinic.triage", %{cases: [one, two]}, opts)

      %{admin: admin, v1: v1, v2: v2}
    end

    test "gives it discovery, a header, a diff and validation", %{admin: admin, v1: v1, v2: v2} do
      suite = entry(:suite)

      # Discovery.
      assert %{items: {:ok, listed}} =
               Enum.find(Artifacts.discover(admin.actor), &(&1.artifact.type == :suite))

      assert MapSet.subset?(MapSet.new([v1.id, v2.id]), MapSet.new(listed, & &1.id))

      # The header.
      assert {:ok, %{id: got}} = Artifacts.get(suite, v2.id, admin.actor)
      assert got == v2.id
      header = Artifacts.header(suite, v2, admin.actor)
      assert %{identity: "clinic.triage", version: 2, lifecycle: {:draft, :draft}} = header
      assert %{lifecycle: {:published, :current}} = Artifacts.header(suite, v1, admin.actor)
      assert {:ok, _who} = Artifacts.header(suite, v1, admin.actor).published_by

      # The diff, against the version before.
      assert {:ok, %{id: id}} = Artifacts.previous(suite, v2, admin.actor)
      assert id == v1.id

      assert {:changes, [%Change{aspect: :cases, kind: :added, subject: "two"}]} =
               Artifacts.diff(suite, Artifacts.previous(suite, v2, admin.actor), v2, [])

      assert Artifacts.previous(suite, v1, admin.actor) == :first

      # Validation.
      assert Artifacts.validation(suite, v2) == {:ok, []}

      assert {:ok, ["case id one is used twice"]} =
               Artifacts.validation(suite, %{v2 | cases: [hd(v2.cases), hd(v2.cases)]})
    end

    test "with no page, component or registry code of its own" do
      for path <- [
            "lib/ash_enterprise_web/live/artifact_live.ex",
            "lib/ash_enterprise_web/components/artifact_components.ex"
          ] do
        refute File.read!(path) =~
                 ~r/AshEnterprise\.(Quality|Execution|Bpmn|Decisions|Mdm|Assistant)\b|AshCompliance/,
               "#{path} names a resource"
      end

      registry = File.read!("lib/ash_enterprise/artifacts.ex")
      assert length(Regex.scan(~r/AshEnterprise\.Quality\.Suite\b/, registry)) == 1
    end
  end

  describe "a draft is not the version a run used (UX-04)" do
    setup do
      admin = AssistantFixtures.tenant!()

      seed = fn version, status ->
        Ash.Seed.seed!(AgentVersion, %{
          organization_id: admin.tenant,
          key: "clinic.triager",
          version: version,
          source: :code,
          instructions: "Read the referral, v#{version}.",
          model_profile: "in_zone",
          toolset: [],
          limits: %{max_steps: 4},
          output_type: "string",
          content_hash: "h#{version}",
          status: status
        })
      end

      published = seed.(1, :published)
      draft = seed.(2, :draft)

      run =
        Ash.Seed.seed!(Run, %{
          organization_id: admin.tenant,
          agent_key: "clinic.triager",
          agent_version_id: published.id,
          owner_type: :user,
          owner_id: admin.user.id,
          run_key: "artifact-#{System.unique_integer([:positive])}",
          mode: :live,
          status: :completed
        })

      %{admin: admin, published: published, draft: draft, run: run}
    end

    test "the run's version is its own, the draft is a draft and another", ctx do
      agent = entry(:agent)

      assert {:this, %{id: id}} =
               Artifacts.used_by(agent, ctx.published, ctx.run.id, ctx.admin.actor)

      assert id == ctx.run.id
      assert {:other, _run} = Artifacts.used_by(agent, ctx.draft, ctx.run.id, ctx.admin.actor)

      assert Artifacts.lifecycle(agent, ctx.draft) == {:draft, :draft}
      assert Artifacts.lifecycle(agent, ctx.published) == {:published, :current}
    end

    test "a run that cannot be read never says which version it used", ctx do
      agent = entry(:agent)
      stranger = AssistantFixtures.tenant!()

      assert Artifacts.used_by(agent, ctx.published, ctx.run.id, stranger.actor) == :unreadable

      assert Artifacts.used_by(agent, ctx.published, Ecto.UUID.generate(), ctx.admin.actor) ==
               :unreadable

      assert Artifacts.used_by(agent, ctx.published, "not-a-uuid", ctx.admin.actor) == :unreadable
      assert Artifacts.used_by(agent, ctx.published, nil, ctx.admin.actor) == nil
      assert Artifacts.used_by(entry(:suite), ctx.published, ctx.run.id, ctx.admin.actor) == nil
    end

    test "a version the viewer cannot read is unreadable, and so is its predecessor", ctx do
      agent = entry(:agent)
      stranger = AssistantFixtures.tenant!()

      assert Artifacts.get(agent, ctx.draft.id, stranger.actor) == :unreadable
      assert Artifacts.get(agent, "not-a-uuid", ctx.admin.actor) == :unreadable
      assert Artifacts.previous(agent, ctx.draft, stranger.actor) == {:unreadable, :from}
      assert {:ok, _v1} = Artifacts.previous(agent, ctx.draft, ctx.admin.actor)
    end

    test "who published is unreadable to a viewer without the audit trail, never invented", ctx do
      member = AssistantFixtures.colleague!(ctx.admin, [])
      assert Artifacts.published_by(entry(:agent), ctx.published, member.actor) == :unreadable

      assert Artifacts.published_by(entry(:agent), ctx.published, ctx.admin.actor) ==
               :not_recorded
    end
  end

  # --- nothing missing reads as unchanged or valid ------------------------------------

  defmodule Raises do
    @behaviour AshEnterprise.Artifacts.Differ
    def aspects, do: [content: "Content"]
    def diff(_old, _new, _opts), do: raise("the differ broke")
  end

  defmodule Errors do
    @behaviour AshEnterprise.Artifacts.Differ
    def aspects, do: [content: "Content"]
    def diff(_old, _new, _opts), do: {:error, :could_not_compare}
  end

  defmodule Garbage do
    @behaviour AshEnterprise.Artifacts.Differ
    def aspects, do: [content: "Content"]
    def diff(_old, _new, _opts), do: :ok
  end

  defmodule FindsNothing do
    @behaviour AshEnterprise.Artifacts.Differ
    def aspects, do: [content: "Content"]
    def diff(_old, _new, _opts), do: {:ok, []}
  end

  defp with_differ(differ), do: %{entry(:suite) | differ: differ}

  describe "what is never read as no changes" do
    setup do
      {old, new} = pair(:suite)
      %{old: old, new: new}
    end

    test "a differ that raises, errors or answers nonsense has failed", %{old: old, new: new} do
      assert {:failed, "the differ broke"} = Artifacts.diff(with_differ(Raises), old, new, [])
      assert {:failed, :could_not_compare} = Artifacts.diff(with_differ(Errors), old, new, [])
      assert {:failed, {:unexpected, :ok}} = Artifacts.diff(with_differ(Garbage), old, new, [])
    end

    test "a version that cannot be read, or a missing prior, is not compared", %{new: new} do
      suite = entry(:suite)
      assert Artifacts.diff(suite, :unreadable, new, []) == {:unreadable, :from}
      assert Artifacts.diff(suite, {:unreadable, :from}, new, []) == {:unreadable, :from}
      assert Artifacts.diff(suite, :first, new, []) == :first
      assert Artifacts.diff(entry(:surface), :unchained, new, []) == :unchained
      assert {:failed, _} = Artifacts.diff(suite, new, :unreadable, [])
      assert {:failed, {:unexpected, nil}} = Artifacts.diff(suite, nil, new, [])
    end

    test "two different types are not compared", %{new: new} do
      {agent, _agent} = pair(:agent)
      assert {:failed, {:unexpected, _}} = Artifacts.diff(entry(:suite), agent, new, [])
    end

    test "a type with no differ has no semantic diff", %{old: old, new: new} do
      assert Artifacts.diff(with_differ(nil), old, new, []) == :no_differ
      assert Artifacts.diff(with_differ(nil), :first, new, []) == :no_differ
      assert Artifacts.aspects(with_differ(nil)) == []
    end

    test "a differ that finds nothing while the content hashes differ is uncovered",
         %{old: old} do
      differ = with_differ(FindsNothing)

      assert Artifacts.diff(differ, %{old | content_hash: "a"}, %{old | content_hash: "b"}, []) ==
               :uncovered

      assert Artifacts.diff(differ, %{old | content_hash: "a"}, %{old | content_hash: "a"}, []) ==
               {:unchanged, :same_content}

      assert Artifacts.diff(differ, old, old, []) == {:unchanged, :compared}
    end

    test "a predecessor numbered after 1 that is not there is hidden, not first" do
      admin = AssistantFixtures.tenant!()

      seed = fn key, version ->
        Ash.Seed.seed!(Quality.Suite, %{
          organization_id: admin.tenant,
          key: key,
          version: version,
          cases: [%{id: "a", input: "SYNTHETIC: a"}],
          status: :draft
        })
      end

      assert Artifacts.previous(entry(:suite), seed.("clinic.later", 3), admin.actor) ==
               {:unreadable, :from}

      assert Artifacts.previous(entry(:suite), seed.("clinic.lone", 1), admin.actor) == :first
    end

    test "a first rule-set revision labelled other than 1 is first, not hidden" do
      admin = AssistantFixtures.tenant!()

      seed = fn name, revision ->
        Ash.Seed.seed!(AshCompliance.Resources.RuleSetRevision, %{
          organization_id: admin.tenant,
          name: name,
          revision: revision,
          layer: :tenant_supplement,
          rules_json: ~s({"combining":"deny_overrides","fact_schema":{},"rules":[]}),
          content_hash: "sha256:synthetic-#{revision}"
        })
      end

      rule_set = entry(:rule_set)
      first = seed.("clinic.labelled", "v1")
      assert Artifacts.previous(rule_set, first, admin.actor) == :first

      # A later revision has an earlier one, read or hidden: never first.
      later = seed.("clinic.labelled", "2026.2")
      refute Artifacts.previous(rule_set, later, admin.actor) == :first
    end
  end

  describe "what is never read as valid" do
    test "a check that raises, errors or answers nonsense has not been checked" do
      suite = entry(:suite)
      {_old, new} = pair(:suite)

      assert {:failed, "boom"} =
               Artifacts.validation(%{suite | validate: fn _ -> raise "boom" end}, new)

      assert Artifacts.validation(%{suite | validate: fn _ -> {:error, :no} end}, new) ==
               {:failed, :no}

      assert {:failed, {:unexpected, :ok}} =
               Artifacts.validation(%{suite | validate: fn _ -> :ok end}, new)

      assert Artifacts.validation(entry(:rule_set), new) == :undeclared
    end

    test "a release whose gate has not run, or whose result is incomplete, is not valid" do
      release = entry(:release)
      manifest = struct(ReleaseManifest, entries: [])

      assert Artifacts.validation(release, %{manifest | gate_result: nil}) ==
               {:failed, :gate_not_run}

      assert Artifacts.validation(release, %{manifest | gate_result: %{"problems" => []}}) ==
               {:failed, :gate_not_run}

      assert Artifacts.validation(release, %{manifest | gate_result: %{"passed" => true}}) ==
               {:failed, :gate_not_run}

      assert {:ok, ["the release gate did not pass"]} =
               Artifacts.validation(release, %{manifest | gate_result: %{"passed" => false}})

      assert Artifacts.validation(release, %{
               manifest
               | gate_result: %{"passed" => true, "problems" => []}
             }) == {:ok, []}
    end

    test "a definition never compiled and a mapping never validated are not checked" do
      assert Artifacts.validation(
               entry(:process),
               struct(AshEnterprise.Bpmn.Definition, graph: nil, errors: [])
             ) == {:failed, :not_compiled}

      assert Artifacts.validation(
               entry(:decision),
               struct(AshEnterprise.Decisions.Definition,
                 graph: nil,
                 errors: [],
                 verification: nil
               )
             ) == {:failed, :not_compiled}

      assert Artifacts.validation(
               entry(:mapping),
               struct(AshEnterprise.Mdm.Mapping, validation_findings: nil)
             ) == {:failed, :not_validated}
    end

    test "a lifecycle state the entry does not name is unknown, never current" do
      {old, _new} = pair(:agent)

      assert Artifacts.lifecycle(entry(:agent), %{old | status: :archived}) ==
               {:archived, :unknown}

      assert Artifacts.lifecycle(entry(:agent), %{old | status: nil}) == {nil, :unknown}
      assert Artifacts.lifecycle(entry(:surface), old) == nil
    end
  end
end
