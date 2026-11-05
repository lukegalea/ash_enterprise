defmodule AshEnterprise.Quality.AdhocComparisonTest do
  @moduledoc """
  Prompt experimentation (ADR 0058, AGT-48): two drafts of an agent's instructions are
  run on the same cases as `:adhoc` suite runs and compared by what each recorded.

    * each suite run is keyed by its draft's `content_hash` (`candidate_digest`), and
      its cases' runs pin that draft, with the case's prompt variables;
    * a variable a case leaves without a value is reported before any run exists, so
      before any model call;
    * `finish` records provenance, with cost labelled: unavailable without priced usage;
    * a result is saved as a case of a draft suite, with its inputs, through `add_case`.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.Execution.Runs

  alias AshEnterprise.Execution
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.Provenance
  alias AshEnterprise.Test.Execution.{Authority, NoNetwork}
  alias AshEnterprise.Test.Quality.Evaluee

  @agent "clinic.evaluee"

  setup do
    in_zone!()
    :ok = NoNetwork.block!()
    clinic = clinic!()
    published = published!(clinic, %{}, Evaluee)
    Authority.start_grant!(clinic.admin, clinic.admin, @agent)
    %{clinic: clinic, published: published}
  end

  defp opts(%{admin: admin, tenant: tenant}), do: [actor: admin.actor, tenant: tenant]

  defp draft!(clinic, published, instructions) do
    Execution.create_agent_draft!(
      %{
        key: @agent,
        instructions: instructions,
        model_profile: published.model_profile,
        toolset: published.toolset,
        limits: published.limits,
        output_type: published.output_type
      },
      opts(clinic)
    )
  end

  defp suite!(clinic, cases, key \\ "clinic.evaluee.prompts") do
    Quality.create_suite_draft!(key, %{cases: cases}, opts(clinic))
  end

  defp case_for(id, clinician) do
    %{
      id: id,
      input: "SYNTHETIC: note the visit of #{clinician}.",
      metadata: %{"variables" => %{"clinician" => clinician}},
      split: :dev,
      assertions: [%{type: :max_steps, limit: 4}]
    }
  end

  defp start_adhoc!(clinic, suite, version) do
    Quality.start_suite_run!(
      suite.id,
      @agent,
      %{mode: :adhoc, agent_version_id: version.id},
      opts(clinic)
    )
  end

  defp case_runs(clinic, suite_run) do
    Execution.list_agent_runs!(
      query: [filter: [origin: :eval], sort: [run_key: :asc]],
      authorize?: false,
      tenant: clinic.tenant
    )
    |> Enum.filter(&String.starts_with?(&1.run_key, "quality:#{suite_run.id}:"))
  end

  defp finish!(clinic, suite_run) do
    for run <- case_runs(clinic, suite_run) do
      for _round <- 1..2 do
        Oban.drain_queue(queue: :agent_runs)
        Oban.drain_queue(queue: :execution)
      end

      run(run)
    end

    AshOban.Test.schedule_and_run_triggers({Quality.SuiteRun, :finish}, drain_queues?: true)
    Quality.get_suite_run!(suite_run.id, oban(clinic.tenant))
  end

  test "two drafts on the same cases give two adhoc runs keyed by content hash",
       %{clinic: clinic, published: published} do
    suite = suite!(clinic, [case_for("ana", "RN-1"), case_for("ben", "RN-2")])
    brief = draft!(clinic, published, "Note the visit of {{clinician}}. Be brief.")
    thorough = draft!(clinic, published, "Note the visit of {{clinician}}. Be thorough.")
    assert brief.content_hash != thorough.content_hash

    script!(for _call <- 1..4, do: {:text, ~s({"done": true})})

    first = start_adhoc!(clinic, suite, brief)
    second = start_adhoc!(clinic, suite, thorough)

    assert {first.mode, first.candidate_digest, first.agent_version_id} ==
             {:adhoc, brief.content_hash, brief.id}

    assert second.candidate_digest == thorough.content_hash

    adhoc =
      Quality.list_suite_runs!(
        query: [filter: [mode: :adhoc, suite_id: suite.id]],
        actor: clinic.admin.actor,
        tenant: clinic.tenant
      )

    assert adhoc |> Enum.map(& &1.candidate_digest) |> Enum.sort() ==
             Enum.sort([brief.content_hash, thorough.content_hash])

    # Each case's run pins the draft, carries the case's values, and causes no effect.
    runs = case_runs(clinic, first)
    assert length(runs) == 2
    assert Enum.all?(runs, &(&1.agent_version_id == brief.id and &1.mode == :eval))

    assert runs |> Enum.map(& &1.variables) |> Enum.sort() == [
             %{"clinician" => "RN-1"},
             %{"clinician" => "RN-2"}
           ]

    finished = finish!(clinic, first)
    assert finished.status == :finished
    assert finished.summary["quality"]["cases"] == 2

    assert_received {:model_request, messages, _tools, _opts}
    prompt = Enum.map_join(messages, " ", &Enum.map_join(&1.content, fn part -> part.text end))
    assert prompt =~ "Note the visit of RN-"
    refute prompt =~ "{{clinician}}"

    provenance = finished.summary["provenance"]

    assert provenance["version"] == %{
             "agent_version_id" => brief.id,
             "version" => brief.version,
             "status" => "draft",
             "content_hash" => brief.content_hash
           }

    assert provenance["model_profile"] == brief.model_profile
    assert provenance["configuration"]["limits"]["max_steps"] == 4
    assert is_integer(provenance["elapsed_ms"]) and provenance["elapsed_ms"] >= 0
    assert provenance["usage"]["calls"] == 2
    # No rate is configured for the model, so there is no cost to show.
    assert provenance["cost"] == %{"label" => "unavailable"}
  end

  test "a missing variable is reported before any run exists or model is called",
       %{clinic: clinic, published: published} do
    cases = [case_for("ana", "RN-1"), %{id: "ben", input: "SYNTHETIC: a visit.", split: :dev}]
    suite = suite!(clinic, cases)
    draft = draft!(clinic, published, "Note the visit of {{clinician}} at {{ room }}.")
    script!([{:text, ~s({"done": true})}])

    assert {:error, %Ash.Error.Invalid{} = error} =
             Quality.start_suite_run(
               suite.id,
               @agent,
               %{mode: :adhoc, agent_version_id: draft.id},
               opts(clinic)
             )

    message = Exception.message(error)
    assert message =~ "case ana gives no value for room"
    assert message =~ "case ben gives no value for clinician, room"

    assert Execution.list_agent_runs!(
             query: [filter: [origin: :eval]],
             authorize?: false,
             tenant: clinic.tenant
           ) == []

    refute_received {:model_request, _messages, _tools, _opts}
  end

  test "only an adhoc suite run names its version, and it names one of the agent's",
       %{clinic: clinic, published: published} do
    suite = suite!(clinic, [case_for("ana", "RN-1")])
    draft = draft!(clinic, published, "Note the visit of {{clinician}}.")

    assert {:error, %Ash.Error.Invalid{} = offline} =
             Quality.start_suite_run(
               suite.id,
               @agent,
               %{mode: :offline, agent_version_id: draft.id},
               opts(clinic)
             )

    assert Exception.message(offline) =~ "only for an adhoc suite run"

    assert {:error, %Ash.Error.Invalid{} = unnamed} =
             Quality.start_suite_run(suite.id, @agent, %{mode: :adhoc}, opts(clinic))

    assert Exception.message(unnamed) =~ "names the version it tries"

    other =
      Execution.create_agent_draft!(
        %{
          key: "clinic.other",
          instructions: "x",
          model_profile: published.model_profile,
          toolset: [],
          limits: published.limits
        },
        opts(clinic)
      )

    assert {:error, %Ash.Error.Invalid{} = foreign} =
             Quality.start_suite_run(
               suite.id,
               @agent,
               %{mode: :adhoc, agent_version_id: other.id},
               opts(clinic)
             )

    assert Exception.message(foreign) =~ "is not a draft or published version of #{@agent}"
  end

  describe "cost" do
    @call %{model: "vendor:small", input_tokens: 2000, output_tokens: 500}

    setup do
      previous = Application.get_env(:ash_enterprise, Provenance, [])
      on_exit(fn -> Application.put_env(:ash_enterprise, Provenance, previous) end)
      Application.put_env(:ash_enterprise, Provenance, [])
      :ok
    end

    test "reads unavailable without priced usage" do
      assert Provenance.cost([]) == %{"label" => "unavailable"}
      assert Provenance.cost([@call]) == %{"label" => "unavailable"}
      assert Provenance.cost([%{@call | input_tokens: nil}]) == %{"label" => "unavailable"}
    end

    test "is an estimate, labelled, once the model's rate is configured" do
      Application.put_env(:ash_enterprise, Provenance,
        prices: %{
          "vendor:small" => %{
            input_per_million: "3.00",
            output_per_million: "15.00",
            currency: "USD"
          }
        }
      )

      assert Provenance.cost([@call, @call]) ==
               %{"label" => "estimated", "amount" => "0.027", "currency" => "USD"}

      # One call with no token counts makes the whole of it unavailable: nothing is guessed.
      assert Provenance.cost([@call, %{@call | output_tokens: nil}]) == %{
               "label" => "unavailable"
             }

      assert Provenance.cost([@call, %{@call | model: "vendor:other"}]) == %{
               "label" => "unavailable"
             }
    end
  end

  test "a result saved as a case becomes a draft-suite case with its inputs",
       %{clinic: clinic, published: published} do
    suite = suite!(clinic, [case_for("ana", "RN-1")])
    draft = draft!(clinic, published, "Note the visit of {{clinician}}.")
    script!([{:text, ~s({"note": "recorded"})}])

    finished = finish!(clinic, start_adhoc!(clinic, suite, draft))

    [result] =
      Quality.list_case_results!(
        query: [filter: [suite_run_id: finished.id]],
        actor: clinic.admin.actor,
        tenant: clinic.tenant
      )

    target = suite!(clinic, [], "clinic.evaluee.saved")

    saved = Quality.save_result_as_suite_case!(target, result.id, "ana-recorded", opts(clinic))

    assert [kept] = saved.cases

    assert %{id: "ana-recorded", input: "SYNTHETIC: note the visit of RN-1.", split: :dev} = kept
    assert kept.metadata["variables"] == %{"clinician" => "RN-1"}
    assert kept.metadata["saved_from"] == %{"suite_run_id" => finished.id, "case_id" => "ana"}
    assert [%{type: :max_steps, limit: 4}] = kept.assertions
    assert Jason.decode!(kept.target) == %{"note" => "recorded"}
    assert saved.status == :draft

    # A saved case is checked like any other: a duplicate id is refused.
    assert {:error, %Ash.Error.Invalid{}} =
             Quality.save_result_as_suite_case(saved, result.id, "ana-recorded", opts(clinic))

    # And a published suite takes no new case, saved or written.
    published_suite = Quality.publish_suite!(saved, opts(clinic))

    assert {:error, %Ash.Error.Invalid{}} =
             Quality.save_result_as_suite_case(published_suite, result.id, "late", opts(clinic))

    assert {:error, %Ash.Error.Invalid{}} =
             Quality.add_suite_case(suite, nil, opts(clinic))
  end
end
