defmodule AshEnterprise.Quality.SuiteTest do
  @moduledoc """
  Evaluation suites (ADR 0058) on the platform base: who may read, run and publish
  them, how their cases are checked and versioned, and the deterministic scorer's
  vocabulary. What a suite run does is `no_live_effects_test.exs`.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{Assertions, CaseResult, Suite, SuiteRun}
  alias AshEnterprise.Security
  alias AshEnterprise.Test.AssistantFixtures

  @record "AshEnterprise.Test.Execution.ClinicNote.record"

  defp case!(id, assertions \\ []),
    do: %{id: id, input: "SYNTHETIC: #{id}", assertions: assertions}

  describe "privileges" do
    test "a new tenant's Administrator holds quality.read, quality.run and quality.publish" do
      seeded = Seeder.seed_tenant(unique_name: "quality-#{System.unique_integer([:positive])}")

      granted = fn resource ->
        name = inspect(resource)

        Security.RolePrivilege
        |> Ash.Query.filter(role_id == ^seeded.role.id and privilege.resource_name == ^name)
        |> Ash.Query.load(:privilege)
        |> Ash.read!(actor: SystemActor.seed(), tenant: seeded.organization.id)
        |> Enum.map(& &1.privilege.access_right)
      end

      # quality.read
      for resource <- [Suite, SuiteRun, CaseResult], do: assert(:read in granted.(resource))
      # quality.run
      assert :create in granted.(SuiteRun)
      # quality.publish
      assert :create in granted.(Suite)
      assert :write in granted.(Suite)
    end

    test "a member with no role reads no suite and starts no suite run" do
      admin = AssistantFixtures.tenant!()
      member = AssistantFixtures.colleague!(admin, [])

      suite =
        Quality.create_suite_draft!("q.read", %{cases: [case!("one")]},
          actor: admin.actor,
          tenant: admin.tenant
        )
        |> Quality.publish_suite!(actor: admin.actor, tenant: admin.tenant)

      assert Quality.list_suites!(actor: member.actor, tenant: member.tenant) == []

      assert {:error, %Ash.Error.Forbidden{}} =
               Quality.start_suite_run(suite.id, "clinic.evaluee",
                 actor: member.actor,
                 tenant: member.tenant
               )
    end

    test "only its suite run records a case result" do
      admin = AssistantFixtures.tenant!()

      assert {:error, _error} =
               Ash.create(
                 CaseResult,
                 %{suite_run_id: Ash.UUID.generate(), case_id: "x", status: :passed},
                 action: :record,
                 actor: SystemActor.oban(),
                 tenant: admin.tenant
               )
    end
  end

  describe "cases" do
    setup do
      %{admin: AssistantFixtures.tenant!()}
    end

    test "are refused with a duplicate id or an assertion missing what it measures", %{
      admin: admin
    } do
      opts = [actor: admin.actor, tenant: admin.tenant]

      assert {:error, %Ash.Error.Invalid{} = error} =
               Quality.create_suite_draft(
                 "q.bad",
                 %{
                   cases: [
                     case!("same"),
                     case!("same", [%{type: :prohibited_effect}, %{type: :max_steps}])
                   ]
                 },
                 opts
               )

      message = Exception.message(error)
      assert message =~ "case id same is used twice"
      assert message =~ "prohibited_effect needs a target"
      assert message =~ "max_steps needs a limit"
    end

    test "are versioned by key, hashed at publish and frozen after", %{admin: admin} do
      opts = [actor: admin.actor, tenant: admin.tenant]
      key = "q.versions.#{System.unique_integer([:positive])}"

      first = Quality.create_suite_draft!(key, %{cases: [case!("a")]}, opts)

      first =
        Quality.add_suite_case!(first, case!("b", [%{type: :tool_called, target: @record}]), opts)

      assert Enum.map(first.cases, & &1[:id]) == ["a", "b"]

      published = Quality.publish_suite!(first, opts)
      assert {published.version, published.status} == {1, :published}
      assert published.content_hash =~ ~r/\A[0-9a-f]{64}\z/

      assert {:error, %Ash.Error.Invalid{}} = Quality.add_suite_case(published, case!("c"), opts)

      second = Quality.create_suite_draft!(key, %{cases: published.cases}, opts)
      assert second.version == 2
      # The same cases hash the same.
      assert Quality.publish_suite!(second, opts).content_hash == published.content_hash

      assert Quality.latest_published_suite!(key, opts).id == second.id
    end
  end

  describe "the scorer" do
    defp observed(overrides \\ %{}) do
      Map.merge(
        %{
          run: %{status: :completed, step_count: 2, error_code: nil, blocked_on: nil},
          tool_names: MapSet.new(["clinic_note_record"]),
          invocations: [%{target: @record, args: %{"title" => "SYNTHETIC"}, approval_mode: :none}],
          answer: %{"recorded" => 1}
        },
        overrides
      )
    end

    defp status(assertion, obs \\ observed()), do: Assertions.evaluate(assertion, obs)["status"]

    test "measures each assertion from what the run recorded" do
      assert status(%{type: :tool_called, target: @record}) == "passed"
      assert status(%{type: :tool_not_called, target: @record}) == "failed"

      assert status(%{type: :args_match, target: @record, args: %{title: "SYNTHETIC"}}) ==
               "passed"

      assert status(%{type: :args_match, target: @record, args: %{title: "other"}}) == "failed"
      assert status(%{type: :prohibited_effect, target: @record}) == "failed"
      assert status(%{type: :approval_requested, target: @record}) == "failed"
      assert status(%{type: :max_steps, limit: 2}) == "passed"
      assert status(%{type: :max_steps, limit: 1}) == "failed"
      assert status(%{type: :within_budget}) == "passed"

      assert status(
               %{type: :within_budget},
               observed(%{run: %{blocked_on: :budget, error_code: nil}})
             ) == "failed"

      assert status(%{type: :schema_valid}) == "passed"
      assert status(%{type: :output_matches, expected: %{recorded: 1}}) == "passed"
      assert status(%{type: :output_matches, expected: %{recorded: 2}}) == "failed"
      assert status(%{type: :process_transition}) == "unmeasured"
      assert status(%{type: :cites}) == "unmeasured"
    end

    test "names the hard assertions, which fail a case whatever else passes" do
      assert Enum.filter(Assertions.vocabulary(), &Assertions.hard?/1) ==
               [:tool_not_called, :prohibited_effect, :within_budget, :schema_valid]

      assert Assertions.evaluate(%{type: :prohibited_effect, target: @record}, observed())["hard"]
    end
  end
end
