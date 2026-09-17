defmodule AshEnterprise.Compliance.KycComplianceTest do
  @moduledoc """
  The KYC vertical slice, end to end: a legacy write, through the strangler
  ledger and the ingester, onto the compliance event log, through the
  projector, into findings and evaluations a subject's own calculations can
  read.

  This is the test that owns the chain-of-custody claim in ADR 0035: nothing
  between the legacy `INSERT` and the finding row is mocked. The trigger is
  the database's, the drain is the worker's, the canonical write is the real
  `:project` action, the events are the real `Kyc.record_from_projection`,
  and the projection folds through `AshCompliance.Testing.drain_sync/2` —
  the same public machinery the async server uses, driven synchronously
  because the sandbox owns the connection.

  The outcome assertions pin the census promises from
  `AshEnterprise.Compliance.KycRules`: missing evidence reads `:unknown`,
  never compliant; the waived control files no finding at all; the
  non-waivable floor cannot be waived; and one tenant's waiver never moves
  another tenant's findings.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshCompliance.Resources.{ComplianceEvaluation, Finding, PolicyBundle, PolicyOverride}
  alias AshCompliance.Testing
  alias AshEnterprise.Accounts.ProjectedUser
  alias AshEnterprise.Compliance.{EventLog, Projector}
  alias AshEnterprise.Ledger.UserDrainWorker
  alias AshEnterprise.Legacy.Estate

  @email_domain "example.org"

  setup do
    # Reviews are officer actions: the event log's create is governed by the
    # role model like every other append, so the tests act as the tenant's
    # seeded compliance administrator.
    seeded = AshEnterprise.Platform.Seeder.seed_legacy_estate()

    org = seeded.organization.id

    officer =
      AshEnterprise.Security.ActorContext.attach(
        seeded.user,
        AshEnterprise.Security.ActorContext.build(seeded.user, tenant: org)
      )

    {:ok, bundle} = AshEnterprise.Compliance.Seeds.seed(org)

    %{org: org, bundle: bundle, officer: officer}
  end

  describe "the full path: legacy write to finding" do
    test "a legacy INSERT becomes findings on every active control, and missing evidence reads unknown" do
      login = "kyc-#{System.unique_integer([:positive])}"
      org = Estate.organization_id()
      bundle = active_bundle(org)

      # 1. The legacy application writes. Raw SQL, because no Ash action here
      #    writes legacy rows — that is the premise of the strangler phase.
      AshEnterprise.Repo.query!(
        "INSERT INTO legacy.users (login, email, first_name, last_name, state) " <>
          "VALUES ($1, $2, 'Kim', 'Subject', 'active')",
        [login, "#{login}@#{@email_domain}"]
      )

      # 2. The ledger trigger wrote a durable row, transactionally with the
      #    legacy write. The seeded estate's own rows are legacy writes too
      #    (the trigger fires on every INSERT), so the backlog is the estate
      #    plus this one — asserted relative, drained whole.
      assert {:ok, backlog} = ledger_backlog()
      assert backlog >= 1

      # 3. The drain ingests the backlog: the canonical write and the
      #    compliance events commit together, or not at all.
      assert {:ok, ^backlog} = UserDrainWorker.drain()
      assert {:ok, 0} = ledger_backlog()

      projected =
        ProjectedUser
        |> Ash.Query.filter(login == ^login)
        |> Ash.read_one!(authorize?: false, tenant: org)

      assert projected.legacy_state == "active"
      assert is_integer(projected.legacy_id)

      subject_id = Integer.to_string(projected.legacy_id)

      # 4. One event per control the ACTIVE bundle declares, for this
      #    subject. The seeded waiver excludes `kyc.review_required`, so its
      #    gap files no event at all. (The estate's other rows also appended
      #    their own reviews during the drain — tests scope by subject.)
      events =
        events_since_marker(0)
        |> Enum.filter(&(&1.metadata["subject_id"] == subject_id))

      assert Enum.sort(Enum.map(events, & &1.metadata["control_id"])) == active_gaps(bundle)

      # 5. The projector folds them. `drain_sync` is the engine's own handler,
      #    grain and ops path, driven inside the sandbox transaction.
      :ok = Testing.drain_sync(Projector, Enum.map(events, &normalize_event/1))

      findings = findings_for(org, subject_id)
      assert length(findings) == length(events)

      by_control = Map.new(findings, &{&1.control_id, &1})

      # Missing evidence is never compliance: the three facts no legacy row
      # can supply all carry `missing: :unknown`, and the finding says why.
      assert %{status: :unknown} = by_control["kyc.identity"]
      assert %{status: :unknown} = by_control["kyc.sanctions"]
      assert %{status: :unknown} = by_control["kyc.mfa"]
      assert by_control["kyc.sanctions"].explanation =~ "sanctions_cleared"

      # What the legacy row CAN say: the e-mail domain is not the migrated
      # one, the jurisdiction is unresolved, and no review was recorded.
      assert %{status: :noncompliant} = by_control["kyc.contact"]
      assert %{status: :noncompliant} = by_control["kyc.jurisdiction"]
      assert %{status: :noncompliant} = by_control["kyc.migration"]
      assert %{status: :noncompliant} = by_control["kyc.welcome"]

      # Applicability excludes: not suspended (floor, balance freeze), not
      # high-risk-regulated (enhanced review), no remediations counter filed.
      assert %{status: :compliant} = by_control["kyc.sanctions_floor"]
      assert %{status: :compliant} = by_control["kyc.accounts"]
      assert %{status: :compliant} = by_control["kyc.enhanced_review"]
      assert %{status: :compliant} = by_control["kyc.remediations"]
      assert %{status: :compliant} = by_control["kyc.tier"]

      # The waived control has no finding row at all — the waiver removed the
      # rule from the bundle, so no event was ever filed for it.
      refute Map.has_key?(by_control, "kyc.review")

      # 6. The subject-facing calculations read the projection, not the engine.
      [loaded] =
        ProjectedUser
        |> Ash.Query.filter(id == ^projected.id)
        |> Ash.Query.load([:kyc_status, :compliant?, :gap_count])
        |> Ash.read!(authorize?: false, tenant: org)

      assert loaded.kyc_status == :noncompliant
      assert loaded.compliant? == false
      assert loaded.gap_count == 4

      # 7. The auditor's truth: one append-only evaluation per finding, each
      #    pinning the bundle hash that produced it.
      evals = evaluations_for(org, subject_id)
      assert length(evals) == length(events)
      assert Enum.all?(evals, &(&1.bundle_hash == bundle.content_hash))

      # The overall outcome combines ALL requirements under `deny_overrides`,
      # so it is :noncompliant whenever anything is — but the evaluations
      # carry the missing-facts list, and that is where "we cannot know"
      # survives the combination.
      assert Enum.any?(evals, &(&1.missing_facts != []))
    end

    test "the drain tolerates a replayed ledger event, and the finding converges" do
      login = "kyc-replay-#{System.unique_integer([:positive])}"
      org = Estate.organization_id()

      AshEnterprise.Repo.query!(
        "INSERT INTO legacy.users (login, email, first_name, last_name, state) " <>
          "VALUES ($1, $2, 'Re', 'Played', 'active')",
        [login, "#{login}@#{@email_domain}"]
      )

      assert {:ok, backlog} = UserDrainWorker.drain()
      assert backlog >= 1

      projected =
        ProjectedUser
        |> Ash.Query.filter(login == ^login)
        |> Ash.read_one!(authorize?: false, tenant: org)

      subject_id = Integer.to_string(projected.legacy_id)

      events =
        events_since_marker(0)
        |> Enum.filter(&(&1.metadata["subject_id"] == subject_id))

      :ok = Testing.drain_sync(Projector, Enum.map(events, &normalize_event/1))

      first = findings_for(org, subject_id) |> Map.new(&{&1.control_id, &1})

      # The at-least-once contract: mark THIS row unprocessed and drain again.
      # The canonical upsert is idempotent (one row, same id) and the
      # compliance events re-append under the same correlation id.
      marker = Enum.max_by(events, & &1.id).id

      AshEnterprise.Repo.query!(
        "UPDATE legacy_change_events SET processed_at = NULL " <>
          "WHERE id = (SELECT max(id) FROM legacy_change_events)"
      )

      assert {:ok, 1} = UserDrainWorker.drain()

      refute is_nil(
               ProjectedUser
               |> Ash.Query.filter(login == ^login)
               |> Ash.read_one!(authorize?: false, tenant: org)
             )

      # Only the events the replay APPENDED are folded: a checkpointed engine
      # would never re-fold history it has already applied.
      re_drained =
        events_since_marker(marker)
        |> Enum.filter(&(&1.metadata["subject_id"] == subject_id))

      :ok = Testing.drain_sync(Projector, Enum.map(re_drained, &normalize_event/1))

      second = findings_for(org, subject_id) |> Map.new(&{&1.control_id, &1})

      # The finding converges: same statuses, same explanations, same bundle.
      assert Map.new(second, fn {k, v} -> {k, {v.status, v.explanation, v.bundle_hash}} end) ==
               Map.new(first, fn {k, v} -> {k, {v.status, v.explanation, v.bundle_hash}} end)

      # What did NOT converge is the breach history: a replayed observation of
      # a breach is another observation. The counter is the record of that.
      assert second["kyc.contact"].breach_count == 2
    end
  end

  describe "waivers" do
    test "the seeded waiver is bounded, attributed and visible in the lineage", %{org: org} do
      waiver =
        PolicyOverride
        |> Ash.Query.filter(organization_id == ^org and rule_id == "kyc.review_required")
        |> Ash.read_one!(authorize?: false)

      assert waiver
      assert waiver.kind == :waive
      assert waiver.approver == "compliance-office"
      assert waiver.compensating_controls == ["manual-review-queue"]
      assert DateTime.compare(waiver.expires_at, DateTime.utc_now()) == :gt

      lineage = compile_lineage(org)
      assert Enum.any?(lineage, &(&1.effect == :excluded_by_waiver))
    end

    test "an expired waiver returns the rule to the effective bundle", %{org: org} do
      {:ok, bundle, _} = AshCompliance.Compiler.compile(organization_id: org)
      assert Enum.any?(bundle.rules, &(&1.id == "kyc.review_required")) == false

      # The compile clock is a parameter: against a date past the waiver's
      # expiry the rule is back, with no action taken — expiry is evaluated,
      # not scheduled.
      long_after =
        DateTime.add(DateTime.utc_now(), 400 * 86_400, :second) |> DateTime.truncate(:second)

      {:ok, bundle_then, lineage_then} =
        AshCompliance.Compiler.compile(organization_id: org, now: long_after)

      assert Enum.any?(bundle_then.rules, &(&1.id == "kyc.review_required"))
      refute Enum.any?(lineage_then, &(&1.effect == :excluded_by_waiver))
    end

    test "waiving the non-waivable floor is refused at compile", %{org: org} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Ash.create(
          PolicyOverride,
          %{
            organization_id: org,
            kind: :waive,
            rule_id: "kyc.sanctions_never_waived",
            reason: "the attempt itself is the test",
            approver: "compliance-office",
            approved_at: now,
            starts_at: now,
            expires_at: DateTime.add(now, 7 * 86_400, :second),
            compensating_controls: ["manual-screening"]
          },
          authorize?: false
        )

      assert {:error, errors} = AshCompliance.Compiler.compile(organization_id: org)
      message = Enum.join(List.wrap(errors), " ")
      assert message =~ "kyc.sanctions_never_waived"
      assert message =~ "can never be waived"
    end
  end

  describe "tenant isolation" do
    test "one tenant's waiver never moves another tenant's findings", %{
      org: org_a,
      officer: officer
    } do
      # A second tenant with the same baseline and its OWN tailoring: the
      # e-mail migration rule waived, which tenant A has not waived.
      other =
        AshEnterprise.Platform.Seeder.seed_tenant(
          unique_name: "t-#{System.unique_integer([:positive])}"
        )

      org_b = other.organization.id
      {:ok, _bundle_b} = AshEnterprise.Compliance.Seeds.seed(org_b)

      other_officer =
        AshEnterprise.Security.ActorContext.attach(
          other.user,
          AshEnterprise.Security.ActorContext.build(other.user, tenant: org_b)
        )

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Ash.create(
          PolicyOverride,
          %{
            organization_id: org_b,
            kind: :waive,
            rule_id: "kyc.email_domain_migrated",
            reason: "tenant B completed its migration early",
            approver: "b-compliance-office",
            approved_at: now,
            starts_at: now,
            expires_at: DateTime.add(now, 10 * 86_400, :second),
            compensating_controls: ["b-review-queue"]
          },
          authorize?: false
        )

      {:ok, bundle_b} = activate_compiled(org_b)

      # The same facts, evaluated under each tenant's own bundle.
      facts = [
        ["customer", "status", "active"],
        ["customer", "jurisdiction", "unknown"],
        ["customer", "email_domain", @email_domain]
      ]

      :ok = AshEnterprise.Compliance.Kyc.record_review(org_a, "a-1", facts, actor: officer)

      :ok =
        AshEnterprise.Compliance.Kyc.record_review(org_b, "b-1", facts, actor: other_officer)

      :ok =
        Testing.drain_sync(Projector, Enum.map(events_since_marker(0), &normalize_event/1))

      findings_a = findings_for(org_a, "a-1") |> Map.new(&{&1.control_id, &1})
      findings_b = findings_for(org_b, "b-1") |> Map.new(&{&1.control_id, &1})

      # Tenant A: the migration gap is live and breached.
      assert findings_a["kyc.migration"].status == :noncompliant
      # Tenant B: the waiver removed the rule, so no finding row exists.
      refute Map.has_key?(findings_b, "kyc.migration")

      # And the bundles that decided all this are different artifacts — the
      # content hash is what an auditor pins, so it must never coincide.
      assert active_bundle(org_a).content_hash != bundle_b.content_hash
    end
  end

  # --- helpers ------------------------------------------------------------------

  defp ledger_backlog do
    %Postgrex.Result{rows: [[count]]} =
      AshEnterprise.Repo.query!(
        "SELECT count(*) FROM legacy_change_events WHERE processed_at IS NULL"
      )

    {:ok, count}
  end

  defp active_bundle(org) do
    PolicyBundle
    |> Ash.Query.filter(organization_id == ^org and status == :active)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp active_gaps(bundle) do
    {:ok, decoded} = AshRules.Ir.decode(bundle.rules_json)

    decoded.rules
    |> Enum.map(& &1.outcome.gap)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Events carry a bigserial id; tests that append events read everything
  # after a marker rather than filtering on the JSONB metadata, which keeps
  # the helper honest about ordering.
  defp events_since_marker(marker) do
    EventLog
    |> Ash.Query.filter(id > ^marker)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
  end

  # The normalized row shape the projector engine hands its handlers — the
  # same shape `AshCompliance.Testing.event/1` builds and `Server` reads off
  # the log.
  defp normalize_event(event) do
    %{
      id: event.id,
      practice_id: event.practice_id,
      user_id: event.user_id,
      occurred_at: event.occurred_at,
      metadata: event.metadata,
      resource: event.resource,
      action: event.action,
      action_type: event.action_type
    }
  end

  defp findings_for(org, subject_id) do
    Finding
    |> Ash.Query.filter(
      organization_id == ^org and subject_type == "user" and subject_id == ^subject_id
    )
    |> Ash.read!(authorize?: false)
  end

  defp evaluations_for(org, subject_id) do
    ComplianceEvaluation
    |> Ash.Query.filter(organization_id == ^org and subject_id == ^subject_id)
    |> Ash.read!(authorize?: false)
  end

  defp compile_lineage(org) do
    {:ok, _bundle, lineage} = AshCompliance.Compiler.compile(organization_id: org)
    lineage
  end

  # Compile then activate, retiring whatever was active before: the projector
  # resolves the tenant's bundle as "most recent ACTIVE", so a compiled-but-
  # unactivated bundle is invisible to it — the lifecycle is the point.
  defp activate_compiled(org) do
    current = active_bundle(org)

    {:ok, bundle} = Ash.create(PolicyBundle, %{organization_id: org}, action: :compile)

    bundle =
      bundle
      |> Ash.Changeset.for_update(:activate, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

    if current do
      current
      |> Ash.Changeset.for_update(:retire, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)
    end

    {:ok, bundle}
  end
end
