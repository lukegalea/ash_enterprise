defmodule AshEnterprise.Audit.Package.Build do
  @moduledoc """
  Assembles the audit package for one tenant and one period: the run of
  `AshEnterprise.Audit.Package.export`.

  It composes what exists and writes nothing. The compliance plane's part is
  `AshCompliance.Ownership.Package.sections/4`, over this application's control file and
  the categories the freshness sweep uses (`AshEnterprise.Compliance.FreshnessSweepWorker`):

    * **controls** — the SOC 2 criteria in scope and the control file's row for each;
    * **evidence** — every artifact collected in the period, hot or archived
      (`AshEnterprise.Audit.ArchivedEvidence`), with its integrity re-checked against its
      hash, plus the newest artifact from each collector before the period; and each
      criterion's freshness at the end of the period, with the waivers in force then;
    * **findings** — the compliance findings open at any time in the period.

  This module adds what the compliance plane cannot observe:

    * **reviews** — the human tasks opened, claimed, decided or cancelled in the period,
      with their outcomes and the process each belongs to;
    * **chain** — `AshEvents.Chain.verify/2` over the tenant's whole chain,
      hot and archived, at export time, the events in the period, and the daily
      verifications recorded in it (`AshEnterprise.Audit.ChainVerifyWorker`);
    * **assessment_results** — all of it as an OSCAL 1.2.3 assessment-results document
      (`AshCompliance.Oscal.AssessmentResults`), with the chain's verification and the
      reviews as observations of their own, a broken chain as a failing finding, and its
      properties in the `urn:ash-enterprise:audit-package` namespace.

  ## Reach

  The action's policy is the grant union over `AshEnterprise.Audit.Package` (see its
  moduledoc). Having passed it, every read here runs as the actor with authorization
  off, and is narrowed in code: the host's tenant-scoped resources by the tenant, the
  compliance plane's rows (organization columns, not Ash tenancy) by the read actions
  that take the organization id. The tenant is the actor's own; any other is refused
  before anything is read.

  ## A broken chain is never a pass

  The chain is verified whole, not only over the period: a row edited after the period
  makes everything after it unverifiable, and a removed row shows as a broken link on
  the row after it, which may fall just outside the period. So `status` is `"broken"`
  when the verifier reports any finding at all, the findings inside the period are
  listed separately, and the OSCAL document carries a finding for it.
  """

  use Ash.Resource.Actions.Implementation

  alias AshCompliance.Oscal.AssessmentResults
  alias AshCompliance.Ownership.Evidence
  alias AshCompliance.Ownership.Package, as: CompliancePackage
  alias AshEnterprise.Audit.{ChainVerifyWorker, EventLog}
  alias AshEnterprise.Compliance.FreshnessSweepWorker
  alias AshEnterprise.Security.ActorContext

  @format "ash_enterprise.audit_package"
  @format_version 1

  # The namespace of the OSCAL document's own properties.
  @namespace "urn:ash-enterprise:audit-package"

  @impl true
  def run(input, _opts, context) do
    from = input.arguments.from
    to = input.arguments.to

    with {:ok, tenant} <- package_tenant(context),
         :ok <- check_period(from, to) do
      {:ok, build(tenant, from, to, context.actor)}
    end
  end

  # The tenant whose package this is: the call's, which for anyone but a system actor
  # must be the tenant their grant was loaded from -- the `organization_id` of the same
  # context `RoleGrant` answered with. A system actor has no grant of its own and passed
  # through the platform's bypass; it exports the tenant it was given.
  defp package_tenant(%{tenant: nil}), do: refuse("an audit package needs a tenant")

  defp package_tenant(%{tenant: tenant, actor: actor}) do
    context = ActorContext.for_actor(actor)

    cond do
      context.system? -> {:ok, to_string(tenant)}
      to_string(context.organization_id) == to_string(tenant) -> {:ok, to_string(tenant)}
      true -> refuse("an audit package covers the exporter's own tenant only")
    end
  end

  defp refuse(message) do
    {:error,
     Ash.Error.Forbidden.exception(
       errors: [Ash.Error.Forbidden.Policy.exception(custom_message: message)]
     )}
  end

  defp check_period(from, to) do
    if DateTime.compare(from, to) == :lt,
      do: :ok,
      else:
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :to,
           message: "must be after `from`"
         )}
  end

  @doc false
  def build(tenant, from, to, actor) do
    generated_at = DateTime.utc_now()
    period = %{from: from, to: to, as_of: Enum.min([to, generated_at], DateTime)}
    # The host's rows are read in the tenant checked above. The compliance plane's carry
    # an organization column and no Ash tenancy, and `sections/4` reads them by it.
    host = [actor: actor, tenant: tenant, authorize?: false]

    reviews = reviews(period, host)
    chain = chain(tenant, period, actor, host)

    compliance =
      tenant
      |> CompliancePackage.sections(from, to,
        controls_file: FreshnessSweepWorker.controls_file(),
        categories: FreshnessSweepWorker.categories(),
        generated_at: generated_at,
        extra_observations: [
          chain_observation(chain),
          reviews_observation(reviews, tenant, period)
        ],
        extra_findings: chain_findings(chain),
        actor: actor,
        authorize?: false
      )
      |> ok!()

    sections = %{
      controls: compliance.controls,
      evidence: compliance.evidence,
      findings: compliance.findings,
      reviews: reviews,
      chain: chain
    }

    manifest = %{
      "format" => @format,
      "format_version" => @format_version,
      "tenant" => tenant,
      "period" => %{"from" => iso(from), "to" => iso(to), "to_is" => "excluded"},
      "freshness_as_of" => iso(period.as_of),
      "generated_at" => iso(generated_at),
      "generated_by" => exporter(actor),
      "oscal_version" => AssessmentResults.oscal_version(),
      "chain_status" => chain["status"],
      "attestation" =>
        "None. Criteria are reported as owned, evidenced or unknown, never as satisfied: " <>
          "an attestation is an auditor's to give."
    }

    oscal =
      AssessmentResults.build(compliance, %{
        namespace: @namespace,
        title: "Audit package #{iso(from)} to #{iso(to)}",
        result_title: "Evidence, findings, reviews and audit-chain verification"
      })

    sections
    |> Map.new(fn {name, section} -> {to_string(name), section} end)
    |> Map.put("manifest", manifest)
    |> Map.put("assessment_results", oscal)
    # One JSON value throughout, so what the action returns is what the files hold.
    |> Jason.encode!()
    |> Jason.decode!()
  end

  # --- reviews ---------------------------------------------------------------

  defp reviews(%{from: from, to: to}, host) do
    tasks =
      AshEnterprise.Bpmn.human_tasks_touched_between!(
        from,
        to,
        [load: [instance: [definition: [:key, :version]]]] ++ host
      )

    %{
      "tasks" =>
        Enum.map(tasks, fn task ->
          %{
            "id" => task.id,
            "name" => task.name,
            "node_id" => task.node_id,
            "status" => to_string(task.status),
            "outcome" => task.outcome,
            "decided_by_id" => task.decided_by_id,
            "assignee_type" => task.assignee_type && to_string(task.assignee_type),
            "assignee_id" => task.assignee_id,
            "delegated_from_id" => task.delegated_from_id,
            "comment" => task.comment,
            "subject_type" => task.subject_type,
            "subject_id" => task.subject_id,
            "opened_at" => iso(task.inserted_at),
            "claimed_at" => task.claimed_at && iso(task.claimed_at),
            "due_at" => task.due_at && iso(task.due_at),
            "last_changed_at" => iso(task.updated_at),
            "instance_id" => task.instance_id,
            "process" => process(task.instance)
          }
        end)
    }
  end

  defp process(%{definition: %{key: key, version: version}}),
    do: %{"key" => key, "version" => version}

  defp process(_instance), do: nil

  # --- chain -----------------------------------------------------------------

  defp chain(tenant, %{from: from, to: to}, actor, host) do
    verified_at = DateTime.utc_now()
    result = AshEvents.Chain.verify(EventLog, tenant)

    in_period =
      Enum.filter(result.findings, fn finding ->
        DateTime.compare(finding.occurred_at, from) != :lt and
          DateTime.compare(finding.occurred_at, to) == :lt
      end)

    %{
      "status" => if(result.findings == [], do: "intact", else: "broken"),
      "verified_at" => iso(verified_at),
      "scope" => "the tenant's whole chain, hot and archived, at export time",
      "checked" => result.checked,
      "skipped_unchained_prefix" => result.skipped_unchained_prefix,
      "anchored_after" => result.anchored_after,
      "events_in_period" => events_in_period(from, to, host),
      "findings" => Enum.map(result.findings, &chain_finding/1),
      "findings_in_period" => length(in_period),
      "daily_verifications" => daily_verifications(tenant, from, to, actor)
    }
  end

  defp chain_finding(finding) do
    %{
      "sequence" => finding.sequence,
      "id" => finding.id,
      "occurred_at" => iso(finding.occurred_at),
      "problem" => to_string(finding.problem)
    }
  end

  defp events_in_period(from, to, host) do
    EventLog
    |> Ash.Query.for_read(:for_export, %{from: from, to: to}, host)
    |> Ash.count!()
  end

  # The scheduled verifications stored in the period, hot or archived: one artifact a day
  # per criterion the worker evidences, so one criterion's are counted. Read whole rather
  # than from the evidence section, which omits content past a size.
  defp daily_verifications(tenant, from, to, actor) do
    [control | _] = ChainVerifyWorker.evidence_controls()
    producer = ChainVerifyWorker.producer()

    runs =
      tenant
      |> Evidence.for_control(control, actor: actor, authorize?: false)
      |> ok!()
      |> Enum.filter(fn artifact ->
        artifact.collector == producer and DateTime.compare(artifact.collected_at, from) != :lt and
          DateTime.compare(artifact.collected_at, to) == :lt
      end)

    with_findings =
      Enum.count(runs, fn artifact ->
        case Jason.decode(artifact.content || "") do
          {:ok, %{"findings" => [_ | _]}} -> true
          _ -> false
        end
      end)

    %{
      "criterion" => control,
      "recorded" => length(runs),
      "with_findings" => with_findings,
      "first_at" => runs |> List.first() |> then(&(&1 && iso(&1.collected_at))),
      "last_at" => runs |> List.last() |> then(&(&1 && iso(&1.collected_at)))
    }
  end

  # --- OSCAL: what the compliance plane cannot observe -----------------------
  #
  # Each `:id` is the name the observation's or finding's version 5 UUID is derived from.

  defp chain_observation(chain) do
    %{
      id: "chain:#{chain["verified_at"]}:#{chain["checked"]}",
      title: "Audit chain verification",
      description:
        "The chain was verified at export: #{chain["checked"]} event(s) checked, " <>
          "#{length(chain["findings"])} finding(s), #{chain["findings_in_period"]} in the period; " <>
          "#{chain["events_in_period"]} event(s) in the period; " <>
          "#{chain["daily_verifications"]["recorded"]} daily verification(s) recorded in it. " <>
          "Status: #{chain["status"]}.",
      props: %{"chain-status" => chain["status"]},
      methods: [:test],
      collected: chain["verified_at"],
      relevant_evidence: [
        %{href: "chain.json", description: "The verifier's result and findings."}
      ]
    }
  end

  defp reviews_observation(reviews, tenant, period) do
    tasks = reviews["tasks"]
    decided = Enum.filter(tasks, &(&1["status"] == "completed"))

    outcomes =
      decided
      |> Enum.frequencies_by(&(&1["outcome"] || "none"))
      |> Enum.sort()
      |> Enum.map_join(", ", fn {outcome, n} -> "#{outcome} #{n}" end)

    %{
      id: "reviews:#{tenant}:#{iso(period.from)}:#{iso(period.to)}",
      title: "Review tasks",
      description:
        "#{length(tasks)} review task(s) touched in the period, #{length(decided)} completed" <>
          if(outcomes == "", do: ".", else: " (#{outcomes})."),
      methods: [:examine],
      collected: period.as_of,
      relevant_evidence: [
        %{href: "reviews.json", description: "Each task, its outcome and who decided it."}
      ]
    }
  end

  # A broken chain fails each criterion the chain's verification evidences.
  defp chain_findings(%{"status" => "intact"}), do: []

  defp chain_findings(chain) do
    problems =
      chain["findings"]
      |> Enum.take(5)
      |> Enum.map_join("; ", &"#{&1["problem"]} at sequence #{&1["sequence"]}")

    for control <- ChainVerifyWorker.evidence_controls() do
      %{
        id: "chain-finding:#{control}:#{chain["verified_at"]}",
        title: "#{control}: the audit chain is broken",
        description:
          "The audit chain does not verify: #{length(chain["findings"])} finding(s) (#{problems}).",
        control_id: control,
        reason: :fail,
        remarks: "The audit trail cannot be shown to be untouched."
      }
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp exporter(actor) do
    context = ActorContext.for_actor(actor)

    cond do
      context.system? -> %{"system_actor" => to_string(Map.get(actor, :name))}
      is_map(actor) and Map.has_key?(actor, :id) -> %{"user_id" => actor.id}
      true -> nil
    end
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, error}), do: raise(Ash.Error.to_error_class(error))

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
