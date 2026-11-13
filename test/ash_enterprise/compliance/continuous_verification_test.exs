defmodule AshEnterprise.Compliance.ContinuousVerificationTest do
  @moduledoc """
  A control that operates on a schedule, with each run stored, and a sweep that says so
  when it stops (q51).

  The chain verification runs daily and records its result as evidence for CC4.1 and CC7.2
  (`AshEnterprise.Audit.ChainVerifyWorker`). The freshness sweep runs hourly
  (`AshEnterprise.Compliance.FreshnessSweepWorker`): evidence that is missing, stale or
  another organization's leaves the criterion unknown, with an open finding.

  The cases where the control reads as not operating come first.
  """

  use AshEnterprise.DataCase, async: false

  alias AshCompliance.Ownership.Evidence
  alias AshEnterprise.Audit.{ChainVerifyWorker, EventLog}
  alias AshEnterprise.Compliance.FreshnessSweepWorker
  alias AshEnterprise.Platform.{Correlation, SystemActor}

  setup do
    Correlation.start_new()
    %{org: Ash.UUID.generate(), other: Ash.UUID.generate()}
  end

  defp create_bu!(name, org) do
    AshEnterprise.Accounts.BusinessUnit
    |> Ash.Changeset.for_create(:create, %{name: name},
      authorize?: false,
      tenant: org,
      actor: SystemActor.seed()
    )
    |> Ash.create!()
  end

  defp finding(org, control) do
    org
    |> AshCompliance.Domain.findings_for_organization!(authorize?: false)
    |> Enum.find(&(&1.control_id == control and &1.subject_type == "evidence_freshness"))
  end

  defp record_verification!(org, days_ago) do
    now = DateTime.utc_now()

    {:ok, _} =
      Evidence.record(org, "CC7.2", ~s({"checked": 1, "findings": []}),
        producer: ChainVerifyWorker.producer(),
        media_type: "application/json",
        method: :test,
        collected_at: DateTime.add(now, -days_ago * 86_400, :second),
        now: now,
        authorize?: false
      )
  end

  describe "the sweep reports a control that is not operating" do
    test "no evidence: the criterion is unknown, with an open finding", ctx do
      assert {:ok, results} = FreshnessSweepWorker.sweep(ctx.org)

      assert %{state: :unknown} = Enum.find(results, &(&1.criterion == "CC7.2"))

      assert %{status: :unknown, gap: "evidence_freshness", resolved_at: nil} =
               finding(ctx.org, "CC7.2")
    end

    test "a stale verification produces its overdue finding", ctx do
      # CC7.2 is daily: a result three days old is a control that stopped running.
      record_verification!(ctx.org, 3)

      assert {:ok, results} = FreshnessSweepWorker.sweep(ctx.org)

      assert %{state: :unknown, reason: :stale} = Enum.find(results, &(&1.criterion == "CC7.2"))

      assert %{status: :unknown, resolved_at: nil, explanation: "stale" <> _} =
               finding(ctx.org, "CC7.2")
    end

    test "another organization's fresh evidence counts for nothing here", ctx do
      record_verification!(ctx.other, 0)

      {:ok, _} = FreshnessSweepWorker.sweep(ctx.org)

      assert %{status: :unknown, resolved_at: nil} = finding(ctx.org, "CC7.2")
    end
  end

  describe "the daily verification" do
    test "records its result as evidence, findings included, for each criterion", ctx do
      create_bu!("One", ctx.org)
      create_bu!("Two", ctx.org)

      assert :ok =
               ChainVerifyWorker.record(
                 AshEvents.Chain.verify(EventLog, ctx.org),
                 DateTime.utc_now()
               )

      for control <- ChainVerifyWorker.evidence_controls() do
        assert [artifact] =
                 AshCompliance.Domain.evidence_for_control!(ctx.org, control, authorize?: false)

        assert artifact.collector == "module:AshEnterprise.Audit.ChainVerifyWorker"
        assert %{"checked" => 2, "findings" => []} = Jason.decode!(artifact.content)
      end
    end

    test "records nothing for the chain with no tenant" do
      assert :skipped =
               ChainVerifyWorker.record(AshEvents.Chain.verify(EventLog, nil), DateTime.utc_now())
    end

    test "runs over every chain from its job", ctx do
      create_bu!("One", ctx.org)

      assert {:ok, results} = ChainVerifyWorker.perform(%Oban.Job{args: %{}})
      assert {ctx.org, 0} in results
      assert [_] = AshCompliance.Domain.evidence_for_control!(ctx.org, "CC7.2", authorize?: false)
    end

    test "a fresh verification resolves the finding the sweep had opened", ctx do
      {:ok, _} = FreshnessSweepWorker.sweep(ctx.org)
      assert %{resolved_at: nil} = finding(ctx.org, "CC7.2")

      create_bu!("One", ctx.org)

      :ok =
        ChainVerifyWorker.record(AshEvents.Chain.verify(EventLog, ctx.org), DateTime.utc_now())

      assert {:ok, results} = FreshnessSweepWorker.sweep(ctx.org)
      assert %{state: :evidenced} = Enum.find(results, &(&1.criterion == "CC7.2"))
      # Resolved, and still `:unknown`: fresh evidence is not a claim of compliance.
      assert %{status: :unknown, resolved_at: %DateTime{}} = finding(ctx.org, "CC7.2")
    end
  end

  describe "the schedule" do
    test "verification, retention and the freshness sweep are on the crontab" do
      crontab =
        :ash_enterprise
        |> Application.fetch_env!(Oban)
        |> Keyword.fetch!(:plugins)
        |> Enum.find_value(fn
          {Oban.Plugins.Cron, opts} -> opts[:crontab]
          _ -> nil
        end)

      scheduled = MapSet.new(crontab, &elem(&1, 1))

      for worker <- [
            AshEnterprise.Audit.ChainVerifyWorker,
            AshEnterprise.Audit.RetentionWorker,
            AshEnterprise.Compliance.FreshnessSweepWorker
          ] do
        assert worker in scheduled, "#{inspect(worker)} is not scheduled"
      end
    end
  end
end
