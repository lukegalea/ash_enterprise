defmodule AshEnterprise.Standards.StandingWorkerTest do
  @moduledoc """
  JS-11: the standards standing check as an in-app, machinery-only job.

  The judge path is the real one with the model replaced by `FakeReqLLM`
  and the band table by a stub resolver, over a synthetic git checkout. The
  tests prove the job judges at most `limit` per question, skips a HEAD it
  already judged, leaves the HEAD unmarked after a judge error or a narrowed
  run, and that the instrument identity reaches the recorded judgment.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Platform.{Correlation, SystemActor}
  alias AshEnterprise.Standards.StandingWorker
  alias AshEnterprise.SystemOne.Judgment
  alias AshEnterprise.SystemOne.StandingHead
  alias AshEnterprise.SystemOne.TestSupport.FakeReqLLM

  @question :policy_check_never_queries
  @instrument %{
    model_version: "winnow:e4b",
    model_digest: "sha256:0123456789abcdef",
    runtime_version: "ollaya-0.0.0-test"
  }

  defmodule FailingReqLLM do
    def evaluate(_spec, _state, _questions, _opts), do: {:error, :econnrefused}
  end

  setup do
    Correlation.start_new()
    System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")
    FakeReqLLM.reset_calls()

    on_exit(fn ->
      System.delete_env("S1_OLLAYA_GPU_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
    end)

    unique_name = "standing-#{System.unique_integer([:positive])}"

    org =
      AshEnterprise.Accounts.Organization
      |> Ash.Changeset.for_create(:create, %{name: "Standing", unique_name: unique_name},
        authorize?: false
      )
      |> Ash.create!()

    root = checkout!()
    repository = "standing-#{System.unique_integer([:positive])}"

    config = [
      enabled: true,
      root: root,
      tenant: unique_name,
      instrument: @instrument,
      standing_opts: [
        repository: repository,
        questions: [@question],
        paths: ["lib"],
        judgments: %{req_llm: FakeReqLLM},
        resolver: &band_table/3
      ]
    ]

    %{config: config, root: root, org: org, repository: repository}
  end

  test "judges at most limit per question, and a narrowed run never marks the HEAD", ctx do
    config = Keyword.put(ctx.config, :limit, 1)

    assert {:ok, %{judged: 1, marked?: false}} = StandingWorker.run(config)
    assert FakeReqLLM.calls() == 1
    assert head(ctx) == nil

    # Narrowed again: the other pending unit is judged, and still no mark.
    assert {:ok, %{judged: 1, marked?: false}} = StandingWorker.run(config)
    assert FakeReqLLM.calls() == 2
    assert head(ctx) == nil
  end

  test "a full run marks the HEAD, and an unchanged HEAD is skipped", ctx do
    assert {:ok, %{judged: 2, errors: 0, marked?: true, head: sha}} =
             StandingWorker.run(ctx.config)

    assert FakeReqLLM.calls() == 2
    assert head(ctx).head == sha

    assert {:ok, :unchanged} = StandingWorker.run(ctx.config)
    assert FakeReqLLM.calls() == 2

    # A new commit moves the HEAD; only the edited unit is judged again.
    write!(ctx.root, "lib/demo/team_check.ex", team_check("actor.context.team_ids != []"))
    commit!(ctx.root, "edit")

    assert {:ok, %{judged: 1, marked?: true, head: new_sha}} = StandingWorker.run(ctx.config)
    assert new_sha != sha
    assert head(ctx).head == new_sha
  end

  test "force judges an unchanged HEAD again", ctx do
    assert {:ok, %{marked?: true}} = StandingWorker.run(ctx.config)
    assert {:ok, %{judged: 0, marked?: true}} = StandingWorker.run([force: true] ++ ctx.config)
  end

  test "a judge error leaves the HEAD unmarked", ctx do
    config =
      Keyword.update!(ctx.config, :standing_opts, fn opts ->
        Keyword.put(opts, :judgments, %{req_llm: FailingReqLLM})
      end)

    assert {:ok, %{judged: 2, errors: 2, marked?: false}} = StandingWorker.run(config)
    assert head(ctx) == nil

    # The next tick, with the transport back, judges the units and marks.
    assert {:ok, %{errors: 0, marked?: true}} = StandingWorker.run(ctx.config)
    assert head(ctx) != nil
  end

  test "the instrument identity reaches the recorded judgment", ctx do
    assert {:ok, %{judged: 2}} = StandingWorker.run(ctx.config)

    rows = Ash.read!(Judgment, tenant: ctx.org.id, authorize?: false)
    assert length(rows) == 2

    for row <- rows do
      assert row.model_version == @instrument.model_version
      assert row.model_digest == @instrument.model_digest
      assert row.runtime_version == @instrument.runtime_version
    end
  end

  test "an instrument that cannot be identified judges nothing", ctx do
    config = Keyword.put(ctx.config, :instrument, fn -> {:error, :runtime_unreachable} end)

    assert {:error, :runtime_unreachable} = StandingWorker.run(config)
    assert FakeReqLLM.calls() == 0
    assert head(ctx) == nil
  end

  test "perform does nothing until enabled" do
    assert {:ok, :disabled} = StandingWorker.perform(%Oban.Job{})
  end

  test "the head resource is reachable by the oban actor alone", ctx do
    assert {:ok, %{marked?: true}} = StandingWorker.run(ctx.config)

    other = SystemActor.projection()
    assert {:ok, nil} = StandingHead.for_scope(ctx.org.id, ctx.repository, actor: other)

    assert {:error, %Ash.Error.Forbidden{}} =
             StandingHead.mark(
               %{subject_tenant_id: ctx.org.id, repository: ctx.repository, head: "abc"},
               actor: other
             )
  end

  # -- helpers ----------------------------------------------------------------

  defp head(ctx),
    do: StandingHead.for_scope!(ctx.org.id, ctx.repository, actor: SystemActor.oban())

  defp band_table(_family, _tenant, _inputs) do
    {:ok,
     %{
       band_table: %{
         "definition_key" => "judgments_band_standards",
         "definition_version" => "1",
         "content_hash" => "sha256:" <> String.duplicate("c", 64),
         "definition_id" => Ash.UUID.generate(),
         "tenant_fork" => nil
       },
       outputs: %{"band" => "admit", "fact_value" => true},
       matched_rule_ids: ["DecisionRule_1"],
       decision_evaluation_id: Ash.UUID.generate()
     }}
  end

  defp checkout! do
    root = Path.join(System.tmp_dir!(), "standing_worker_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    write!(root, "lib/demo/team_check.ex", team_check("actor.context.team_id != nil"))
    git!(root, ["init", "--quiet"])
    commit!(root, "init")
    root
  end

  defp team_check(body) do
    """
    defmodule Demo.TeamCheck do
      use Ash.Policy.SimpleCheck

      def describe(_), do: "member of the team"
      def match?(actor, _context, _opts), do: #{body}
    end
    """
  end

  defp write!(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp commit!(root, message) do
    git!(root, ["add", "-A"])

    git!(root, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@example.test",
      "commit",
      "--quiet",
      "-m",
      message
    ])
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    output
  end
end
