defmodule AshEnterprise.Compliance.Soc2PackTest do
  @moduledoc """
  The `soc2` pack (`priv/packs/soc2/`): every operator process template `ash_compliance`
  ships has exactly one row in the pack's map, a recipe that starts a human-only review or a
  stated reason no audited event can, and the periodic ones fall due on a schedule.

  Refusals first: a map with a template missing, doubled or unknown, a row that is empty,
  double or has a blank reason, a recipe that points nowhere, a scheduled template with no
  schedule, a pack that would carry authority; then what an install leaves (drafts only,
  once, in one tenant) and what the schedule does (one occurrence per period, only where a
  recipe is published, and the recipe's process starts). SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0]

  alias AshCompliance.Processes.Templates
  alias AshEnterprise.Automation.Occurrence
  alias AshEnterprise.Bpmn.{Definition, Instance, Packs, Subscription}
  alias AshEnterprise.Compliance.{ScheduledReviewWorker, TemplateMap}
  alias AshEnterprise.Platform.SystemActor

  @pack "soc2"

  defp manifest! do
    {:ok, manifest} = TemplateMap.manifest(@pack)
    manifest
  end

  defp others! do
    for name <- Packs.names() -- [@pack], into: %{} do
      {:ok, manifest} = TemplateMap.manifest(name)
      {name, manifest}
    end
  end

  defp problems(manifest), do: TemplateMap.problems(manifest, packs: others!())

  defp rows(manifest), do: manifest["templates"]

  defp with_rows(manifest, rows), do: Map.put(manifest, "templates", rows)

  defp row!(manifest, template), do: Enum.find(rows(manifest), &(&1["template"] == template))

  describe "a map that is wrong is refused" do
    test "a template with no row, with two rows, and a row for no template" do
      manifest = manifest!()
      [first | rest] = rows(manifest)

      assert [missing, orphan] = problems(with_rows(manifest, rest))
      assert missing =~ "template #{first["template"]} has 0 rows"
      assert orphan =~ "is used by 0 rows"

      assert Enum.any?(
               problems(with_rows(manifest, [first | rows(manifest)])),
               &(&1 =~ "#{first["template"]} has 2 rows")
             )

      stray = %{"template" => "no_such_template", "reason" => "x"}

      assert Enum.any?(
               problems(with_rows(manifest, [stray | rows(manifest)])),
               &(&1 =~ ~s|"no_such_template", which is not a template|)
             )
    end

    test "a row that is empty, double, or has a blank reason" do
      manifest = manifest!()
      reason_row = row!(manifest, "oversight_meeting")
      recipe_row = row!(manifest, "log_alert_review")

      swap = fn replacement ->
        manifest
        |> rows()
        |> Enum.map(&if(&1["template"] == replacement["template"], do: replacement, else: &1))
        |> then(&with_rows(manifest, &1))
      end

      assert Enum.any?(
               problems(swap.(%{"template" => "oversight_meeting"})),
               &(&1 =~ "neither a recipe, a reference nor a reason")
             )

      assert Enum.any?(
               problems(swap.(Map.put(reason_row, "recipe", recipe_row["recipe"]))),
               &(&1 =~ "more than one of recipe, reference and reason")
             )

      for blank <- ["", "   ", nil] do
        assert Enum.any?(
                 problems(swap.(Map.put(reason_row, "reason", blank))),
                 &(&1 =~ "oversight_meeting: the reason is blank")
               )
      end
    end

    test "a recipe or reference that points at nothing" do
      manifest = manifest!()
      recipe_row = row!(manifest, "log_alert_review")
      ref_row = row!(manifest, "break_glass")
      file_row = row!(manifest, "access_request")

      swap = fn replacement ->
        manifest
        |> rows()
        |> Enum.map(&if(&1["template"] == replacement["template"], do: replacement, else: &1))
        |> then(&with_rows(manifest, &1))
      end

      assert Enum.any?(
               problems(swap.(Map.put(recipe_row, "recipe", "soc2.nothing"))),
               &(&1 =~ "log_alert_review: recipe \"soc2.nothing\" is not in the pack")
             )

      missing_process =
        Map.update!(manifest, "recipes", fn recipes ->
          Enum.map(recipes, fn
            %{"key" => "soc2.log_alert_review.due"} = recipe ->
              Map.put(recipe, "process_key", "soc2.nothing")

            recipe ->
              recipe
          end)
        end)

      assert Enum.any?(
               problems(missing_process),
               &(&1 =~ "starts a process the pack does not hold")
             )

      bad_pack = put_in(ref_row, ["reference", "recipe"], "security_alerts.nothing")

      assert Enum.any?(
               problems(swap.(bad_pack)),
               &(&1 =~ "break_glass: pack \"security_alerts\" has no recipe")
             )

      bad_file = put_in(file_row, ["reference", "file"], "priv/bpmn/nothing.bpmn")

      assert Enum.any?(
               problems(swap.(bad_file)),
               &(&1 =~ "access_request: referenced file")
             )
    end

    test "a recipe no row uses, and a recipe two rows use" do
      manifest = manifest!()

      orphan =
        Map.update!(manifest, "recipes", fn recipes ->
          [%{"key" => "soc2.orphan", "process_key" => "soc2.log_alert_review"} | recipes]
        end)

      assert ["recipe soc2.orphan is used by 0 rows, not one"] = problems(orphan)

      twice = [row!(manifest, "log_alert_review") | rows(manifest)]
      assert Enum.any?(problems(with_rows(manifest, twice)), &(&1 =~ "has 2 rows"))
    end

    test "a scheduled template has a scheduled recipe that waits for its own period" do
      manifest = manifest!()
      scheduled = Enum.filter(Templates.all(), &(&1.trigger == :schedule))
      assert length(scheduled) == 7

      swap = fn replacement ->
        manifest
        |> rows()
        |> Enum.map(&if(&1["template"] == replacement["template"], do: replacement, else: &1))
        |> then(&with_rows(manifest, &1))
      end

      reason = %{"template" => "log_alert_review", "reason" => "Done by hand."}

      assert Enum.any?(
               problems(swap.(reason)),
               &(&1 =~ "runs on a schedule, so its row says trigger schedule")
             )

      no_trigger = Map.delete(row!(manifest, "log_alert_review"), "trigger")
      assert Enum.any?(problems(swap.(no_trigger)), &(&1 =~ "so its row says trigger schedule"))

      other_template =
        Map.update!(manifest, "recipes", fn recipes ->
          Enum.map(recipes, fn
            %{"key" => "soc2.log_alert_review.due"} = recipe ->
              Map.put(
                recipe,
                "guard_feel",
                ~s|data.type = "compliance.review_due" and data.data.template = "vendor_review"|
              )

            recipe ->
              recipe
          end)
        end)

      assert Enum.any?(
               problems(other_template),
               &(&1 =~ "does not wait for compliance.review_due")
             )

      claims = Map.put(row!(manifest, "vulnerability_triage"), "trigger", "schedule")
      assert Enum.any?(problems(swap.(claims)), &(&1 =~ "is not scheduled by ash_compliance"))
    end

    test "a pack manifest cannot carry authority: causing_person and standing_grant are refused" do
      for authority <- ["causing_person", "standing_grant"] do
        root = Path.join(System.tmp_dir!(), "soc2-#{System.unique_integer([:positive])}")
        dir = Path.join(root, "soc2")
        File.mkdir_p!(dir)
        on_exit(fn -> File.rm_rf!(root) end)

        manifest =
          Map.update!(manifest!(), "recipes", fn [first | rest] ->
            [Map.put(first, "authority", authority) | rest]
          end)

        File.write!(Path.join(dir, "pack.json"), Jason.encode!(manifest))

        for process <- manifest["processes"],
            do:
              File.cp!(
                Path.join([Packs.root(), @pack, process["file"]]),
                Path.join(dir, process["file"])
              )

        assert {:error, message} = Packs.load(@pack, root)
        assert message =~ "cannot"
      end
    end
  end

  describe "the committed map" do
    test "every one of the nineteen templates has exactly one row, and the map is consistent" do
      assert length(Templates.all()) == 19
      manifest = manifest!()

      assert problems(manifest) == []

      named = manifest |> rows() |> Enum.map(& &1["template"]) |> Enum.sort()
      assert named == Templates.all() |> Enum.map(& &1.key) |> Enum.sort()
      assert named == Enum.uniq(named)
    end

    test "eight rows are recipes of this pack, four reuse another, seven give a reason" do
      rows = rows(manifest!())

      assert Enum.count(rows, &Map.has_key?(&1, "recipe")) == 8
      assert Enum.count(rows, &Map.has_key?(&1, "reference")) == 4
      assert Enum.count(rows, &Map.has_key?(&1, "reason")) == 7
    end

    test "the pack loads, and every recipe in it is human tasks only and starts a process of its own" do
      assert {:ok, pack} = Packs.load(@pack)
      assert length(pack.recipes) == 8
      assert length(pack.processes) == 8

      manifest = manifest!()
      assert Enum.all?(manifest["recipes"], &(&1["authority"] == "human_tasks_only"))

      assert Enum.all?(
               manifest["recipes"],
               &(&1["match_resource"] == "AshEnterprise.Automation.Occurrence")
             )
    end
  end

  describe "installed" do
    test "as drafts only, once, and into one tenant" do
      admin = tenant!()
      other = tenant!()

      assert {:ok, %{processes: processes, recipes: recipes}} =
               Subscription.install_pack(@pack, actor: admin.actor, tenant: admin.tenant)

      assert map_size(processes) == 8 and map_size(recipes) == 8
      assert Enum.all?(Map.values(processes) ++ Map.values(recipes), &(&1 == :created))

      subscriptions = Ash.read!(Subscription, authorize?: false, tenant: admin.tenant)
      assert length(subscriptions) == 8

      assert Enum.all?(
               subscriptions,
               &(&1.status == :draft and &1.authority == :human_tasks_only)
             )

      assert Enum.all?(subscriptions, &is_nil(&1.accountable_person_id))

      definitions = Ash.read!(Definition, authorize?: false, tenant: admin.tenant)
      assert length(definitions) == 8
      assert Enum.all?(definitions, &(&1.status == :draft and &1.errors in [nil, []]))

      refute admin.tenant in Subscription.trigger_tenants()

      assert {:ok, %{processes: again_p, recipes: again_r}} =
               Subscription.install_pack(@pack, actor: admin.actor, tenant: admin.tenant)

      assert Enum.all?(Map.values(again_p) ++ Map.values(again_r), &(&1 == :existing))
      assert length(Ash.read!(Subscription, authorize?: false, tenant: admin.tenant)) == 8
      assert length(Ash.read!(Definition, authorize?: false, tenant: admin.tenant)) == 8

      assert [] == Ash.read!(Subscription, authorize?: false, tenant: other.tenant)
      assert [] == Ash.read!(Definition, authorize?: false, tenant: other.tenant)
    end
  end

  describe "the schedule" do
    test "a period is one text that does not repeat" do
      assert ScheduledReviewWorker.period("weekly", ~D[2026-12-31]) == "2026-W53"
      assert ScheduledReviewWorker.period("weekly", ~D[2027-01-01]) == "2026-W53"
      assert ScheduledReviewWorker.period("weekly", ~D[2027-01-04]) == "2027-W01"
      assert ScheduledReviewWorker.period("monthly", ~D[2026-11-13]) == "2026-11"
      assert ScheduledReviewWorker.period("quarterly", ~D[2026-12-31]) == "2026-Q4"
      assert ScheduledReviewWorker.period("quarterly", ~D[2027-01-01]) == "2027-Q1"
      assert ScheduledReviewWorker.period("semiannual", ~D[2026-07-01]) == "2026-H2"
      assert ScheduledReviewWorker.period("annual", ~D[2026-11-13]) == "2026"
      assert ScheduledReviewWorker.period("daily", ~D[2026-11-13]) == "2026-11-13"
    end

    test "the worker covers exactly the templates ash_compliance schedules" do
      assert ScheduledReviewWorker.scheduled() |> Enum.map(& &1.key) |> Enum.sort() ==
               ~w(effective_access_review log_alert_review policy_review_acknowledgement
                  restore_test_attestation risk_register_review training_attestation
                  vendor_review)
    end

    defp occurrences(tenant),
      do: Ash.read!(Occurrence, actor: SystemActor.oban(), tenant: tenant)

    defp publish!(tenant, key) do
      opts = [actor: SystemActor.process(), tenant: tenant]
      {:ok, pack} = Packs.load(@pack)
      process = Enum.find(pack.processes, &(&1.key == key))
      recipe = Enum.find(pack.recipes, &(&1.attrs.process_key == key))

      process
      |> Map.take([:key, :name, :xml])
      |> Definition.create!(opts)
      |> Definition.publish!(opts)

      recipe.attrs |> Subscription.create!(opts) |> Subscription.publish!(opts)
    end

    test "a tenant with no published recipe collects nothing" do
      quiet = tenant!()
      assert {:ok, _} = ScheduledReviewWorker.perform(%Oban.Job{})
      assert occurrences(quiet.tenant) == []
    end

    test "a period opens one review, in the tenant that published its recipe only" do
      listening = tenant!()
      quiet = tenant!()
      publish!(listening.tenant, "soc2.log_alert_review")

      assert {:ok, _} = ScheduledReviewWorker.perform(%Oban.Job{})
      assert {:ok, _} = ScheduledReviewWorker.perform(%Oban.Job{})

      rows = occurrences(listening.tenant)
      assert Enum.all?(rows, &(&1.type == "compliance.review_due"))

      assert rows |> Enum.map(& &1.data["template"]) |> Enum.sort() ==
               ScheduledReviewWorker.scheduled() |> Enum.map(& &1.key) |> Enum.sort()

      assert occurrences(quiet.tenant) == []

      AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => listening.tenant}})
      AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => listening.tenant}})

      instances =
        Instance
        |> Ash.Query.for_read(:read)
        |> Ash.read!(actor: SystemActor.process(), tenant: listening.tenant)

      assert [instance] = instances
      instance = Ash.load!(instance, :definition, authorize?: false, tenant: listening.tenant)
      assert instance.definition.key == "soc2.log_alert_review"
    end
  end
end
