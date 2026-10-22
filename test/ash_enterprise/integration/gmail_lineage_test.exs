defmodule AshEnterprise.Integration.GmailLineageTest do
  @moduledoc """
  The Lineage app's done-when, proved on a simulated Gmail sync (synthetic
  mailbox over `Req.Test`, the real scoped lander, the real projection):

    * the sync shows up as one run from the mailbox to the canonical tables:
      `gmail.source → ingestion.gmail.sync → ingestion_source_objects →
      canonical.projection.gmail → canonical_messages`;
    * opening its audit entries works, both ways: the run lists the entries
      it wrote (the same correlation id), and an entry opens its run;
    * the linked account links to its latest sync run;
    * a failed sync is a red run.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.LineageFixtures, only: [inline_store!: 0, quietly: 1]

  alias AshEnterprise.Canonical.Projections
  alias AshEnterprise.Integration.{Gmail, LinkedAccount}
  alias AshEnterprise.Integration.Nango.Proxy
  alias AshEnterprise.Lineage.{Graph, JobRun, Run}
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces.Records
  alias AshEnterprise.Test.GmailSyntheticMailbox
  alias AshEnterpriseWeb.A2ui.{AccountsUI, AuditUI, LineageUI}

  require Ash.Query

  @moduletag :tmp_dir

  @app_envs [
    AshEnterprise.Integration.Gmail.Sync,
    AshEnterprise.Canonical.Projections.Gmail,
    AshEnterprise.Canonical.Projections.ZoneAdmission,
    AshEnterprise.Zones
  ]

  setup ctx do
    inline_store!()
    previous_secret = System.get_env("NANGO_SECRET_KEY")
    previous = Map.new(@app_envs, &{&1, Application.get_env(:ash_enterprise, &1)})

    System.put_env("NANGO_SECRET_KEY", "nango-test-secret-not-a-real-key")
    Enum.each(@app_envs, &Application.delete_env(:ash_enterprise, &1))

    on_exit(fn ->
      if previous_secret,
        do: System.put_env("NANGO_SECRET_KEY", previous_secret),
        else: System.delete_env("NANGO_SECRET_KEY")

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:ash_enterprise, key, value),
          else: Application.delete_env(:ash_enterprise, key)
      end
    end)

    unique = System.unique_integer([:positive])
    email = "lineage-#{unique}@lineage.synthetic.test"

    seeded =
      quietly(fn ->
        seeded =
          Seeder.seed_tenant(name: "LN #{unique}", unique_name: "ln-#{unique}", email: email)

        Seeder.grant_platform_operator(seeded.user)
        seeded
      end)

    actor =
      ActorContext.attach(
        seeded.user,
        ActorContext.build(seeded.user, tenant: seeded.organization.id)
      )

    declare_zone(ctx.tmp_dir)

    account =
      quietly(fn ->
        LinkedAccount.link!(
          %{provider_config_key: "google-mail", connection_id: "conn-ln-#{unique}"},
          actor: actor,
          tenant: seeded.organization.id
        )
        |> LinkedAccount.tag_for_zone!(%{data_class: :internal, residency: "CA"},
          tenant: seeded.organization.id,
          authorize?: false
        )
      end)

    %{actor: actor, tenant: seeded.organization.id, account: account}
  end

  describe "a Gmail sync" do
    setup do
      box = start_supervised!(GmailSyntheticMailbox)
      Req.Test.stub(Proxy, GmailSyntheticMailbox.plug(box))
      GmailSyntheticMailbox.add_message(box, thread_id: "thread-a", subject: "LN-SUBJECT-A")
      GmailSyntheticMailbox.add_message(box, thread_id: "thread-b", subject: "LN-SUBJECT-B")
      :ok
    end

    test "is one run from the mailbox to the canonical tables", ctx do
      assert {:ok, %{projection: %{projected: 2}}} = sync_step(ctx)

      [run] = runs(ctx)
      assert run.job_label == "ingestion.gmail.sync"
      assert run.state == :complete

      job_runs =
        JobRun
        |> Ash.Query.filter(lineage_run_id == ^run.id)
        |> Ash.read!(actor: ctx.actor, tenant: ctx.tenant)
        |> Map.new(&{JobRun.label(&1), &1})

      assert %{state: :complete} = job_runs["ingestion.gmail.sync"]
      assert %{state: :complete} = projection = job_runs["canonical.projection.gmail"]

      assert projection.inputs == [
               %{"namespace" => "ingestion", "name" => "ingestion_source_objects"}
             ]

      assert %{"namespace" => "canonical", "name" => "canonical_messages"} in projection.outputs

      # The canonical writes are in the run too, as their own jobs.
      assert Enum.any?(Map.keys(job_runs), &String.starts_with?(&1, "canonical.message."))

      {:ok, graph} = Graph.derive(actor: ctx.actor, tenant: ctx.tenant)
      id = Map.new(graph.nodes, &{&1.label, &1.id})
      edges = MapSet.new(graph.edges, &{&1.from, &1.to})

      path = [
        "ingestion/gmail.source",
        "ingestion.gmail.sync",
        "ingestion/ingestion_source_objects",
        "canonical.projection.gmail",
        "canonical/canonical_messages"
      ]

      for [from, to] <- Enum.chunk_every(path, 2, 1, :discard) do
        assert MapSet.member?(edges, {id[from], id[to]}), "no edge #{from} → #{to}"
      end
    end

    test "opens its audit entries, and an entry opens its run", ctx do
      {:ok, _summary} = sync_step(ctx)
      [run] = runs(ctx)

      # The run's detail lists the audit entries it wrote, each opening on
      # the Audit trail.
      lineage = data_model(LineageUI, ctx, %{"run" => run.id})
      assert lineage["detail"]["run"]["label"] == "ingestion.gmail.sync"
      entries = lineage["records"]["audit_entries"]
      assert entries != []
      assert Enum.any?(entries, &(&1["resource"] =~ "Canonical.Message"))

      assert Enum.all?(entries, fn entry ->
               match?(%{"surface" => "audit"}, entry["_links"]["occurred_at"])
             end)

      %{"_links" => %{"occurred_at" => %{"recordId" => entry_id}}} = hd(entries)
      assert {:ok, %{surface: %{key: :audit}}} = Records.open(:audit, entry_id, ctx.actor)

      # The entry's detail links back to the run.
      audit = data_model(AuditUI, ctx, %{"entry" => entry_id})

      assert %{"surface" => "lineage", "recordId" => run_id} =
               audit["detail"]["entry"]["_links"]["run"]

      assert run_id == run.id
      assert {:ok, %{surface: %{key: :lineage}}} = Records.open(:lineage, run.id, ctx.actor)

      # Every entry of the run carries its correlation id.
      assert run
             |> Ash.load!(:audit_entries, actor: ctx.actor, tenant: ctx.tenant)
             |> Map.get(:audit_entries)
             |> Enum.all?(&(&1.correlation_id == run.id))
    end

    test "the linked account links to its latest sync run", ctx do
      {:ok, _summary} = sync_step(ctx)
      [run] = runs(ctx)

      accounts = data_model(AccountsUI, ctx, %{"account" => ctx.account.id})

      assert %{"surface" => "lineage", "recordId" => run_id} =
               accounts["detail"]["account"]["_links"]["latest_run"]

      assert run_id == run.id
    end
  end

  test "a failed Gmail sync is a red run", ctx do
    Req.Test.stub(Proxy, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => %{"code" => 401, "message" => "LN-SYNTHETIC unauthorized"}})
    end)

    assert {:cancel, _reason} = sync_step(ctx)

    [run] = runs(ctx)
    assert run.state == :failed
    refute run.error_message =~ "LN-SYNTHETIC"

    lineage = data_model(LineageUI, ctx, %{})
    assert [%{"_badge_tone_state" => "danger"}] = lineage["records"]["table"]

    markers = lineage["diagram"]["graph"]["markers"] |> Map.values() |> List.flatten()

    assert [%{"status" => "failed", "tone" => "danger", "link" => %{"surface" => "lineage"}}] =
             Enum.filter(markers, &(&1["status"] == "failed"))
  end

  # One sync step as its worker runs it: in a fresh correlation (an Oban job
  # is a new process, so a new correlation id), not the test process's.
  defp sync_step(ctx) do
    AshEnterprise.Platform.Correlation.start_new()
    Gmail.Sync.step(ctx.actor, ctx.account.id)
  end

  defp runs(ctx) do
    Run
    |> Ash.Query.filter(linked_account_id == ^ctx.account.id)
    |> Ash.Query.load([:state, :error_message])
    |> Ash.read!(actor: ctx.actor, tenant: ctx.tenant)
  end

  defp data_model(ui, ctx, selection) do
    opts = [actor: ctx.actor, tenant: ctx.tenant]

    %{"updateDataModel" => %{"value" => value}} =
      AshA2ui.Info.build_data_model(
        ui,
        opts ++ [context_state: AshA2ui.Info.context_state_for(ui, selection, opts)]
      )

    value
  end

  defp declare_zone(tmp_dir) do
    today = Date.utc_today()
    path = Path.join(tmp_dir, "lineage-zone.json")

    File.write!(
      path,
      Jason.encode!(%{
        "id" => "lineage-zone",
        "jurisdiction" => "CA-ON",
        "classification_ceiling" => "customer_confidential",
        "inadmissible_restrictions" => ["US"],
        "declared_by" => "Test Operator",
        "declared_at" => Date.to_iso8601(Date.add(today, -1)),
        "review_by" => Date.to_iso8601(Date.add(today, 30))
      })
    )

    Application.put_env(:ash_enterprise, AshEnterprise.Zones, declarations: [path])
    Application.put_env(:ash_enterprise, Projections.ZoneAdmission, zone: "lineage-zone")
    Application.put_env(:ash_enterprise, Projections.Gmail, zone_gate: Projections.ZoneAdmission)
  end
end
