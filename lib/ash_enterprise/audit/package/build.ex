defmodule AshEnterprise.Audit.Package.Build do
  @moduledoc """
  Assembles the audit package for one tenant and one period: the run of
  `AshEnterprise.Audit.Package.export`.

  It composes what exists and writes nothing:

    * **criteria** — the SOC 2 criteria in the audit's categories
      (`AshCompliance.Ownership.Criteria`, the categories the freshness sweep uses) and
      the control file's row for each (`AshCompliance.Ownership.ControlFile`);
    * **evidence** — every artifact collected in the period, hot or archived
      (`AshCompliance.Resources.EvidenceArtifact`, `AshEnterprise.Audit.ArchivedEvidence`),
      with its integrity re-checked against its hash, plus the newest artifact from
      each collector before the period; and each criterion's freshness at the end of
      the period, evaluated by `AshCompliance.Ownership.Freshness` over the artifacts
      collected by then and the waivers in force then;
    * **findings** — the compliance findings open at any time in the period;
    * **reviews** — the human tasks opened, claimed, decided or cancelled in the period,
      with their outcomes and the process each belongs to;
    * **chain** — `AshEnterprise.Audit.Chain.verify/1` over the tenant's whole chain,
      hot and archived, at export time, the events in the period, and the daily
      verifications recorded in it (`AshEnterprise.Audit.ChainVerifyWorker`);
    * **assessment_results** — the same as an OSCAL assessment-results document
      (`AshEnterprise.Audit.Package.Oscal`).

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

  alias AshCompliance.Domain, as: Compliance
  alias AshCompliance.Ownership.{ControlFile, Criteria, Evidence, Freshness}
  alias AshEnterprise.Audit
  alias AshEnterprise.Audit.{Chain, ChainVerifyWorker, EventLog}
  alias AshEnterprise.Audit.Package.Oscal
  alias AshEnterprise.Compliance.FreshnessSweepWorker
  alias AshEnterprise.Security.ActorContext

  @format "ash_enterprise.audit_package"
  @format_version 1

  # Evidence content is carried inline when it is text and small; anything else is
  # carried by its hash, which is what pins its identity.
  @inline_limit 64 * 1024

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
    as_of = Enum.min([to, generated_at], DateTime)
    # The compliance plane's rows carry an organization column and no Ash tenancy;
    # the host's carry both. Either way the tenant is the one checked above.
    plane = [actor: actor, authorize?: false]
    host = [actor: actor, tenant: tenant, authorize?: false]

    categories = FreshnessSweepWorker.categories()
    criteria = Criteria.in_categories(categories)
    controls_path = FreshnessSweepWorker.controls_file()
    loaded = ControlFile.load(controls_path)

    artifacts = Map.new(criteria, &{&1.id, artifacts(tenant, &1.id, plane)})
    known_by_end = Map.new(artifacts, fn {id, list} -> {id, collected_before(list, as_of)} end)

    overrides =
      Compliance.valid_policy_overrides!(
        tenant,
        as_of,
        [load: [:starts_at, :expires_at]] ++ plane
      )

    freshness =
      Freshness.evaluate_all(loaded, known_by_end,
        categories: categories,
        now: as_of,
        overrides: overrides
      )

    period = %{from: from, to: to, as_of: as_of}

    sections = %{
      controls: controls(criteria, categories, controls_path, loaded),
      evidence: evidence(criteria, freshness, artifacts, period),
      findings: findings(tenant, period, plane),
      reviews: reviews(period, host),
      chain: chain(tenant, artifacts, period, host)
    }

    manifest = %{
      "format" => @format,
      "format_version" => @format_version,
      "tenant" => tenant,
      "period" => %{"from" => iso(from), "to" => iso(to), "to_is" => "excluded"},
      "freshness_as_of" => iso(as_of),
      "generated_at" => iso(generated_at),
      "generated_by" => exporter(actor),
      "oscal_version" => Oscal.oscal_version(),
      "chain_status" => sections.chain["status"],
      "attestation" =>
        "None. Criteria are reported as owned, evidenced or unknown, never as satisfied: " <>
          "an attestation is an auditor's to give."
    }

    oscal =
      Oscal.assessment_results(sections, %{
        tenant: tenant,
        from: from,
        to: to,
        as_of: as_of,
        generated_at: generated_at
      })

    sections
    |> Map.new(fn {name, section} -> {to_string(name), section} end)
    |> Map.put("manifest", manifest)
    |> Map.put("assessment_results", oscal)
    # One JSON value throughout, so what the action returns is what the files hold.
    |> Jason.encode!()
    |> Jason.decode!()
  end

  # --- criteria --------------------------------------------------------------

  defp controls(criteria, categories, path, loaded) do
    rows =
      case loaded do
        {:ok, %{rows: rows}} -> Enum.filter(rows, &is_map/1)
        {:error, _} -> []
      end

    %{
      "framework" => "SOC 2 Trust Services Criteria (2017)",
      "categories" => Enum.map(categories, &to_string/1),
      "control_file" => control_file(path, loaded),
      "criteria" =>
        Enum.map(criteria, fn criterion ->
          %{
            "id" => criterion.id,
            "category" => to_string(criterion.category),
            "title" => criterion.title,
            "row" => Enum.find(rows, &(&1["id"] == criterion.id))
          }
        end)
    }
  end

  defp control_file(path, {:ok, %{document: document}}) do
    %{
      "path" => path,
      "loaded" => true,
      "sha256" => document |> Jason.encode!() |> Evidence.sha256(),
      "frameworks" => document["frameworks"]
    }
  end

  defp control_file(path, {:error, error}) do
    %{"path" => path, "loaded" => false, "error" => ControlFile.describe_error(error)}
  end

  # --- evidence --------------------------------------------------------------

  # Hot and archived, one list: during a retention move an artifact can be in both, and
  # the copy hashes to the same row, so it is kept once.
  defp artifacts(tenant, control_id, plane) do
    hot =
      tenant
      |> Compliance.evidence_for_control!(control_id, plane)
      |> Enum.map(&artifact(&1, "hot"))

    archived =
      tenant
      |> Audit.archived_evidence_for_control!(control_id, plane)
      |> Enum.map(&artifact(&1, "archive"))

    (hot ++ archived)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.collected_at, DateTime)
  end

  defp artifact(row, location) do
    %{
      id: row.id,
      control_id: row.control_id,
      collector: row.collector,
      method: to_string(row.method),
      media_type: row.media_type,
      collected_at: row.collected_at,
      hash: row.hash,
      content: row.content,
      subject_type: row.subject_type,
      subject_id: row.subject_id,
      retention_class: row.retention_class,
      chain_of_custody: row.chain_of_custody || [],
      location: location
    }
  end

  defp collected_before(artifacts, at),
    do: Enum.filter(artifacts, &(DateTime.compare(&1.collected_at, at) == :lt))

  defp evidence(criteria, freshness, artifacts, period) do
    by_id = Map.new(freshness, &{&1.criterion, &1})

    %{
      "freshness_as_of" => iso(period.as_of),
      "criteria" =>
        Enum.map(criteria, fn criterion ->
          list = Map.get(artifacts, criterion.id, [])

          %{
            "id" => criterion.id,
            "freshness" => freshness_json(Map.get(by_id, criterion.id)),
            "artifacts" => list |> reported(period) |> Enum.map(&artifact_json(&1, period))
          }
        end)
    }
  end

  # The artifacts collected in the period, and before it the newest one from each
  # collector: what an annual control's freshness at the start of the period rests on.
  defp reported(artifacts, %{from: from, to: to}) do
    {before, rest} = Enum.split_with(artifacts, &(DateTime.compare(&1.collected_at, from) == :lt))
    inside = Enum.filter(rest, &(DateTime.compare(&1.collected_at, to) == :lt))

    basis =
      before
      |> Enum.group_by(& &1.collector)
      |> Enum.map(fn {_collector, list} -> List.last(list) end)

    Enum.sort_by(basis ++ inside, & &1.collected_at, DateTime)
  end

  defp artifact_json(artifact, %{from: from}) do
    {content, omitted} = inline(artifact)

    %{
      "id" => artifact.id,
      "control_id" => artifact.control_id,
      "collector" => artifact.collector,
      "method" => artifact.method,
      "media_type" => artifact.media_type,
      "collected_at" => iso(artifact.collected_at),
      "in_period" => DateTime.compare(artifact.collected_at, from) != :lt,
      "sha256" => artifact.hash,
      "integrity" => integrity(artifact),
      "location" => artifact.location,
      "subject_type" => artifact.subject_type,
      "subject_id" => artifact.subject_id,
      "retention_class" => artifact.retention_class,
      "chain_of_custody" => artifact.chain_of_custody,
      "content" => content,
      "content_omitted" => omitted
    }
  end

  # `AshCompliance.Ownership.Evidence.verify/1`'s rule, over a hot or archived row alike:
  # verified only when the stored bytes are present and hash to the row's hash.
  @doc false
  def integrity(%{content: content, hash: hash}) when is_binary(content) and content != "" do
    if Evidence.sha256(content) == hash, do: "verified", else: "hash_mismatch"
  end

  def integrity(_artifact), do: "no_content"

  defp inline(%{content: content, media_type: type}) when is_binary(content) do
    cond do
      byte_size(content) > @inline_limit -> {nil, "larger than #{@inline_limit} bytes"}
      not text?(type) -> {nil, "not text (#{type})"}
      not String.valid?(content) -> {nil, "not valid UTF-8"}
      true -> {content, nil}
    end
  end

  defp inline(_artifact), do: {nil, "no content stored"}

  defp text?(type),
    do: String.starts_with?(type, "text/") or type in ["application/json", "application/xml"]

  defp freshness_json(nil), do: nil

  defp freshness_json(result) do
    %{
      "state" => to_string(result.state),
      "reason" => result.reason && to_string(result.reason),
      "detail" => result.detail,
      "sources" => result.sources,
      "latest_at" => result.latest_at && iso(result.latest_at),
      "silenced_by" => waiver(result.silenced_by)
    }
  end

  defp waiver(nil), do: nil

  defp waiver(by) do
    %{
      "approver" => by[:approver] && to_string(by[:approver]),
      "expires_at" => by[:expires_at] && iso(by[:expires_at]),
      "reason" => by[:reason]
    }
  end

  # --- findings --------------------------------------------------------------

  defp findings(tenant, %{from: from, to: to}, plane) do
    open_in_period =
      tenant
      |> Compliance.findings_for_organization!(plane)
      |> Enum.filter(fn finding ->
        seen = finding.first_seen_at || finding.inserted_at

        DateTime.compare(seen, to) == :lt and
          (is_nil(finding.resolved_at) or DateTime.compare(finding.resolved_at, from) != :lt)
      end)
      |> Enum.sort_by(&{&1.control_id, &1.subject_type, &1.subject_id})

    %{
      "note" =>
        "A finding is the projection's current state, read at export time; " <>
          "those open at any time in the period are listed.",
      "findings" =>
        Enum.map(open_in_period, fn finding ->
          %{
            "id" => finding.id,
            "control_id" => finding.control_id,
            "subject_type" => finding.subject_type,
            "subject_id" => finding.subject_id,
            "status" => to_string(finding.status),
            "severity" => finding.severity && to_string(finding.severity),
            "gap" => finding.gap,
            "breach_count" => finding.breach_count,
            "first_seen_at" => finding.first_seen_at && iso(finding.first_seen_at),
            "last_seen_at" => finding.last_seen_at && iso(finding.last_seen_at),
            "resolved_at" => finding.resolved_at && iso(finding.resolved_at),
            "explanation" => finding.explanation,
            "bundle_hash" => finding.bundle_hash,
            "rule_ids" => finding.rule_ids
          }
        end)
    }
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

  defp chain(tenant, artifacts, %{from: from, to: to}, host) do
    verified_at = DateTime.utc_now()
    result = Chain.verify(tenant)

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
      "daily_verifications" => daily_verifications(artifacts, from, to)
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

  # The scheduled verifications stored in the period: one artifact a day per
  # criterion the worker evidences, so one criterion's are counted.
  defp daily_verifications(artifacts, from, to) do
    [control | _] = ChainVerifyWorker.evidence_controls()
    producer = ChainVerifyWorker.producer()

    runs =
      artifacts
      |> Map.get(control, [])
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

  # --- helpers ---------------------------------------------------------------

  defp exporter(actor) do
    context = ActorContext.for_actor(actor)

    cond do
      context.system? -> %{"system_actor" => to_string(Map.get(actor, :name))}
      is_map(actor) and Map.has_key?(actor, :id) -> %{"user_id" => actor.id}
      true -> nil
    end
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
