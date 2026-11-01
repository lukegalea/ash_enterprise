defmodule AshEnterprise.SystemOne.JudgedStateTest do
  @moduledoc """
  S1-98: the text a model judged is sealed on its judgment as it is
  recorded, opens for a person who may read the ledger, reads as no text
  once its scope is shredded, and the backfill seals the rows recorded
  before, only while their text is unchanged.

  The judge path is the real one (the standing job over a synthetic
  checkout, the generated judge action, the recorder, the ledger), with the
  model replaced by `FakeReqLLM` and every answer banded to review.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.SystemOne.Support

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Erasure
  alias AshEnterprise.Platform.{Correlation, Seeder, SystemActor}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Standards.{Questions, Standing}
  alias AshEnterprise.SystemOne.{Banding, JudgedState, Judgment, ReviewSource}
  alias AshEnterprise.SystemOne.JudgedState.Backfill
  alias AshEnterprise.SystemOne.TestSupport.FakeReqLLM

  @question :policy_check_never_queries

  setup do
    Correlation.start_new()
    System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")
    FakeReqLLM.reset_calls()

    on_exit(fn ->
      System.delete_env("S1_OLLAYA_GPU_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
    end)

    n = System.unique_integer([:positive])

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(name: "Judged text #{n}", unique_name: "judged-text-#{n}")

    root = Path.join(System.tmp_dir!(), "judged_state_#{n}")
    on_exit(fn -> File.rm_rf!(root) end)
    write!(root, "lib/demo/team_check.ex", check("TeamCheck", "actor.context.team_id != nil"))

    %{
      root: root,
      org: organization.id,
      actor: ActorContext.attach(admin, ActorContext.build(admin, tenant: organization.id)),
      opts: [repository: "judged-#{n}", questions: [@question], paths: ["lib"]]
    }
  end

  describe "recording a judgment" do
    test "seals the judged text, which opens for a reader of the ledger", ctx do
      results = Standing.run(ctx.root, run_opts(ctx))
      assert [_describe, _match] = results
      assert Enum.all?(results, &match?({:ok, %{band: :review}}, &1.result))

      rows = Ash.read!(Judgment, tenant: ctx.org, authorize?: false)
      assert length(rows) == 2
      opened = ReviewSource.open_state(rows, actor: ctx.actor, tenant: ctx.org)

      for row <- rows do
        state = judged_state!(ctx, row.subject_id)
        assert opened[row.id] == JudgedState.text(state)
        assert opened[row.id] =~ "def "
        assert JudgedState.digest(state) == row.state_digest
      end

      # Sealed under the tenant's judged-text scope: a code unit has no scope
      # of its own.
      assert {:ok, %{status: :active}} =
               Erasure.scope_by_ref(:data_subject, JudgedState.scope_ref(ctx.org),
                 authorize?: false
               )

      # The audit log holds the ciphertext, never the text.
      refute Enum.any?(ledger_events(:record), &(inspect(&1) =~ "actor.context.team_id"))

      # Without an actor the review source opens nothing.
      assert ReviewSource.open_state(rows, tenant: ctx.org) == %{}
    end

    test "a shredded scope reads as no text, and later judgments record none", ctx do
      Standing.run(ctx.root, run_opts(ctx))

      ctx.org
      |> JudgedState.scope_ref()
      |> then(&Erasure.scope_by_ref!(:data_subject, &1, authorize?: false))
      |> Erasure.shred_scope!(JudgedState.scope_ref(ctx.org), "test shred", authorize?: false)

      rows = Ash.read!(Judgment, tenant: ctx.org, authorize?: false)
      opened = ReviewSource.open_state(rows, actor: ctx.actor, tenant: ctx.org)
      assert map_size(opened) == 2
      assert Enum.all?(Map.values(opened), &is_nil/1)

      # The unit changes, so it is judged again: recorded, without its text.
      write!(
        ctx.root,
        "lib/demo/team_check.ex",
        check("TeamCheck", "actor.context.team_ids != []")
      )

      assert [%{observation_id: id}] =
               ctx.root
               |> Standing.run(run_opts(ctx))
               |> Enum.filter(&match?({:ok, _banded}, &1.result))

      assert %Judgment{state_ciphertext: nil} =
               Ash.get!(Judgment, id, tenant: ctx.org, authorize?: false)
    end
  end

  describe "the backfill" do
    setup ctx do
      write!(ctx.root, "lib/demo/role_check.ex", check("RoleCheck", "actor.role == :admin"))
      %{root: ctx.root}
    end

    test "seals a row whose text is unchanged, leaves a changed one, and is idempotent", ctx do
      unchanged = legacy!(ctx, "Demo.TeamCheck.match?/3")
      changed = legacy!(ctx, "Demo.RoleCheck.match?/3")
      erased = legacy!(ctx, "Demo.TeamCheck.describe/1", sealed: true)
      tombstone!(erased.id, tenant: ctx.org)

      write!(ctx.root, "lib/demo/role_check.ex", check("RoleCheck", "actor.role in [:admin]"))

      # A dry run counts and writes nothing.
      expected = %{awaiting: 2, sealed: 1, changed: 1, unresolved: 0, shredded: 0}
      assert backfill(ctx) == expected
      assert unsealed?(ctx, unchanged) and unsealed?(ctx, changed)

      assert backfill(ctx, apply?: true) == expected
      unchanged = Ash.get!(Judgment, unchanged.id, tenant: ctx.org, authorize?: false)

      assert ReviewSource.open_state([unchanged], actor: ctx.actor, tenant: ctx.org) == %{
               unchanged.id => JudgedState.text(judged_state!(ctx, unchanged.subject_id))
             }

      assert unsealed?(ctx, changed)
      assert unsealed?(ctx, erased)

      # A second run seals nothing more and rewrites nothing.
      assert backfill(ctx, apply?: true) ==
               %{awaiting: 1, sealed: 0, changed: 1, unresolved: 0, shredded: 0}

      assert Ash.get!(Judgment, unchanged.id, tenant: ctx.org, authorize?: false).state_ciphertext ==
               unchanged.state_ciphertext
    end

    test "a unit that is gone is unresolved", ctx do
      legacy!(ctx, "Demo.RoleCheck.match?/3")
      File.rm!(Path.join(ctx.root, "lib/demo/role_check.ex"))

      assert backfill(ctx, apply?: true) ==
               %{awaiting: 1, sealed: 0, changed: 0, unresolved: 1, shredded: 0}
    end

    test "the seal update fills an empty state only", ctx do
      row = legacy!(ctx, "Demo.TeamCheck.match?/3", sealed: true)

      assert {:error, %Ash.Error.Invalid{}} =
               row
               |> Ash.Changeset.for_update(:seal_state, %{state_ciphertext: "other"},
                 actor: SystemActor.migration(),
                 tenant: ctx.org
               )
               |> Ash.update()
    end
  end

  # A judgment recorded before sealing existed: the unit's real digest, no
  # text, banded to review. `sealed: true` records it with a text instead.
  defp legacy!(ctx, name_path, opts \\ []) do
    declared = Questions.declared(@question)
    subject_id = "#{ctx.opts[:repository]}:#{path_of(name_path)}##{name_path}"
    state = judged_state!(ctx, subject_id)

    judgment =
      record!(
        [
          tenant: ctx.org,
          question_id: declared.question_id,
          question_hash: declared.question_hash,
          family: to_string(declared.family),
          subject_type: "AshEnterprise.Standards.CodeUnit",
          subject_id: subject_id,
          state_digest: JudgedState.digest(state)
        ] ++
          if(opts[:sealed], do: [state_ciphertext: "sealed elsewhere"], else: [])
      )

    review_banding!(judgment, ctx.org)
    judgment
  end

  defp judged_state!(ctx, subject_id) do
    question = Questions.fetch!(@question)
    {:ok, unit} = Standing.find_unit(ctx.root, question, subject_id)
    Standing.judged_state(question, unit)
  end

  defp path_of("Demo.TeamCheck." <> _), do: "lib/demo/team_check.ex"
  defp path_of("Demo.RoleCheck." <> _), do: "lib/demo/role_check.ex"

  defp backfill(ctx, opts \\ []),
    do: Backfill.run(Keyword.merge([tenant: ctx.org, root: ctx.root], opts))

  defp unsealed?(ctx, judgment),
    do:
      is_nil(Ash.get!(Judgment, judgment.id, tenant: ctx.org, authorize?: false).state_ciphertext)

  defp ledger_events(action) do
    EventLog
    |> Ash.Query.filter(resource == ^Judgment and action == ^action)
    |> Ash.read!(authorize?: false)
  end

  defp run_opts(ctx) do
    Keyword.merge(ctx.opts,
      tenant: ctx.org,
      judgments: %{req_llm: FakeReqLLM},
      resolver: &review_table/3
    )
  end

  defp review_table(_family, _tenant, _inputs) do
    {:ok,
     %{
       band_table: %{
         "definition_key" => "judgments_band_standards",
         "definition_version" => "1",
         "content_hash" => "sha256:" <> String.duplicate("c", 64),
         "definition_id" => Ash.UUID.generate(),
         "tenant_fork" => nil
       },
       outputs: %{"band" => "review"},
       matched_rule_ids: ["rule_review"],
       decision_evaluation_id: Ash.UUID.generate()
     }}
  end

  defp review_banding!(judgment, org) do
    Banding
    |> Ash.Changeset.for_create(
      :record,
      %{
        observation_ids: [judgment.id],
        band: :review,
        reason_code: "below_conformal_threshold",
        matched_rule_ids: ["rule_review"],
        band_table: %{"definition_key" => "judgments_band_standards", "definition_version" => "1"},
        decision_evaluation_id: Ash.UUID.generate(),
        inputs: %{"family" => judgment.family},
        mode: :live
      },
      actor: SystemActor.process(),
      tenant: org
    )
    |> Ash.create!()
  end

  defp check(name, body) do
    """
    defmodule Demo.#{name} do
      use Ash.Policy.SimpleCheck

      def describe(_), do: "#{name}"
      def match?(actor, _context, _opts), do: #{body}
    end
    """
  end

  defp write!(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end
end
