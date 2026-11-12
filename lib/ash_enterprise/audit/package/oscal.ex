defmodule AshEnterprise.Audit.Package.Oscal do
  @moduledoc """
  The audit package as an OSCAL assessment-results document, OSCAL 1.2.3 (NIST). The
  official JSON schema it validates against is vendored with its licence in
  `priv/vendor/oscal/1.2.3/`.

  One result covers the period. Its reviewed controls are the criteria in scope, and it
  carries:

    * an **observation** for every evidence artifact collected in the period (its
      method is the artifact's assessment method), one for each criterion's freshness
      at the end of the period, one for the audit chain's verification and one for
      the review tasks;
    * a **finding** for every criterion whose freshness at the end of the period is
      unknown, for every compliance finding open in the period that is not compliant,
      and, when the chain is broken, for each criterion the chain's verification
      evidences.

  ## Never "satisfied"

  OSCAL's objective status is `satisfied` or `not-satisfied`. This document never says
  `satisfied`: `ash_compliance` answers owned, evidenced or unknown, and only an
  auditor attests. An evidenced criterion therefore has observations and no finding;
  an unknown one has a `not-satisfied` finding whose reason is `other`, because
  unknown is never a pass; a noncompliant one has a `not-satisfied` finding whose
  reason is `fail`.

  ## Identifiers

  OSCAL requires version 4 or 5 UUIDs. Every identifier here is a version 5 UUID
  derived from what it names (the artifact's id, the criterion, the package's tenant,
  period and generation time), so the same package always carries the same ones.
  Extra facts travel as properties in the `urn:ash-enterprise:audit-package` namespace.
  """

  @oscal_version "1.2.3"
  @ns "urn:ash-enterprise:audit-package"
  # RFC 4122's URL namespace: the derived names are URNs.
  @uuid_namespace "6ba7b811-9dad-11d1-80b4-00c04fd430c8"
  @token ~r/^(\p{L}|_)(\p{L}|\p{N}|[.\-_])*$/u

  @doc "The OSCAL version the document declares and is validated against."
  def oscal_version, do: @oscal_version

  @doc "The namespace of this document's own properties."
  def namespace, do: @ns

  @doc """
  The document for `sections` (the package's sections, as `AshEnterprise.Audit.Package.Build`
  assembles them, before JSON encoding) and `meta` (`:tenant`, `:from`, `:to`, `:as_of`,
  `:generated_at`).
  """
  def assessment_results(sections, meta) do
    package = "#{meta.tenant}:#{iso(meta.from)}:#{iso(meta.to)}:#{iso(meta.generated_at)}"

    observations =
      artifact_observations(sections.evidence) ++
        freshness_observations(sections.evidence, meta) ++
        [chain_observation(sections.chain), reviews_observation(sections.reviews, meta)]

    findings =
      freshness_findings(sections.evidence) ++
        compliance_findings(sections.findings) ++ chain_findings(sections.chain)

    result =
      %{
        "uuid" => uuid5("result:" <> package),
        "title" => "Evidence, findings, reviews and audit-chain verification",
        "description" =>
          "The audit package for one organization over [#{iso(meta.from)}, #{iso(meta.to)}). " <>
            "Freshness is evaluated at #{iso(meta.as_of)}.",
        "start" => iso(meta.from),
        "end" => iso(meta.to),
        "props" => [prop("tenant", meta.tenant), prop("chain-status", sections.chain["status"])],
        "reviewed-controls" => %{
          "control-selections" => [
            %{
              "include-controls" =>
                Enum.map(sections.controls["criteria"], &%{"control-id" => token(&1["id"])})
            }
          ]
        },
        "observations" => observations,
        "findings" => findings,
        "remarks" =>
          "No objective is reported as satisfied. Criteria are owned, evidenced or unknown; " <>
            "an attestation is an auditor's."
      }
      |> drop_empty()

    %{
      "assessment-results" => %{
        "uuid" => uuid5("assessment-results:" <> package),
        "metadata" => %{
          "title" => "Audit package #{iso(meta.from)} to #{iso(meta.to)}",
          "last-modified" => iso(meta.generated_at),
          "version" => "1",
          "oscal-version" => @oscal_version
        },
        "import-ap" => %{
          "href" => "controls.json",
          "remarks" =>
            "No assessment plan is published. The criteria in scope and the control " <>
              "file's row for each are in controls.json beside this document."
        },
        "results" => [result]
      }
    }
  end

  # --- observations ----------------------------------------------------------

  defp artifact_observations(evidence) do
    for criterion <- evidence["criteria"],
        artifact <- criterion["artifacts"],
        artifact["in_period"] do
      %{
        "uuid" => uuid5("artifact:#{artifact["id"]}"),
        "title" => "Evidence for #{criterion["id"]}",
        "description" =>
          "Artifact #{artifact["id"]} from #{artifact["collector"]} (#{artifact["media_type"]}), " <>
            "sha256 #{artifact["sha256"]}; integrity #{artifact["integrity"]}.",
        "props" => [
          prop("criterion", criterion["id"]),
          prop("integrity", artifact["integrity"]),
          prop("location", artifact["location"])
        ],
        "methods" => [String.upcase(artifact["method"])],
        "collected" => artifact["collected_at"],
        "relevant-evidence" => [
          %{
            "href" => "evidence.json",
            "description" =>
              "Artifact #{artifact["id"]} in evidence.json, with its content when it is text."
          }
        ]
      }
    end
  end

  defp freshness_observations(evidence, meta) do
    for criterion <- evidence["criteria"], freshness = criterion["freshness"], freshness do
      %{
        "uuid" => uuid5("freshness:#{meta.tenant}:#{criterion["id"]}:#{iso(meta.as_of)}"),
        "title" => "Freshness of #{criterion["id"]}",
        "description" => "#{freshness["state"]}: #{freshness["detail"]}",
        "props" => [
          prop("criterion", criterion["id"]),
          prop("freshness-state", freshness["state"])
        ],
        "methods" => ["EXAMINE"],
        "collected" => iso(meta.as_of)
      }
    end
  end

  defp chain_observation(chain) do
    %{
      "uuid" => uuid5("chain:#{chain["verified_at"]}:#{chain["checked"]}"),
      "title" => "Audit chain verification",
      "description" =>
        "The chain was verified at export: #{chain["checked"]} event(s) checked, " <>
          "#{length(chain["findings"])} finding(s), #{chain["findings_in_period"]} in the period; " <>
          "#{chain["events_in_period"]} event(s) in the period; " <>
          "#{chain["daily_verifications"]["recorded"]} daily verification(s) recorded in it. " <>
          "Status: #{chain["status"]}.",
      "props" => [prop("chain-status", chain["status"])],
      "methods" => ["TEST"],
      "collected" => chain["verified_at"],
      "relevant-evidence" => [
        %{"href" => "chain.json", "description" => "The verifier's result and findings."}
      ]
    }
  end

  defp reviews_observation(reviews, meta) do
    tasks = reviews["tasks"]
    decided = Enum.filter(tasks, &(&1["status"] == "completed"))

    outcomes =
      decided
      |> Enum.frequencies_by(&(&1["outcome"] || "none"))
      |> Enum.sort()
      |> Enum.map_join(", ", fn {outcome, n} -> "#{outcome} #{n}" end)

    %{
      "uuid" => uuid5("reviews:#{meta.tenant}:#{iso(meta.from)}:#{iso(meta.to)}"),
      "title" => "Review tasks",
      "description" =>
        "#{length(tasks)} review task(s) touched in the period, #{length(decided)} completed" <>
          if(outcomes == "", do: ".", else: " (#{outcomes})."),
      "methods" => ["EXAMINE"],
      "collected" => iso(meta.as_of),
      "relevant-evidence" => [
        %{"href" => "reviews.json", "description" => "Each task, its outcome and who decided it."}
      ]
    }
  end

  # --- findings --------------------------------------------------------------

  defp freshness_findings(evidence) do
    for criterion <- evidence["criteria"],
        freshness = criterion["freshness"],
        freshness && freshness["state"] == "unknown" do
      waiver =
        case freshness["silenced_by"] do
          %{} = by -> " Silenced by a waiver until #{by["expires_at"]}."
          _ -> ""
        end

      %{
        "uuid" => uuid5("freshness-finding:#{criterion["id"]}:#{freshness["detail"]}"),
        "title" => "#{criterion["id"]}: evidence is unknown",
        "description" => "#{freshness["reason"]}: #{freshness["detail"]}.#{waiver}",
        "target" =>
          target(
            criterion["id"],
            "other",
            "Unknown is never a pass: no fresh evidence was found."
          )
      }
    end
  end

  defp compliance_findings(findings) do
    for finding <- findings["findings"],
        finding["subject_type"] != "evidence_freshness",
        finding["status"] != "compliant" do
      reason = if finding["status"] == "noncompliant", do: "fail", else: "other"

      %{
        "uuid" => uuid5("finding:#{finding["id"]}"),
        "title" => "#{finding["control_id"]}: #{finding["status"]}",
        "description" => finding_description(finding),
        "props" => [prop("finding-id", finding["id"]), prop("control", finding["control_id"])],
        "target" => target(finding["control_id"], reason, "Projected compliance finding.")
      }
    end
  end

  defp finding_description(%{"explanation" => text}) when is_binary(text) and text != "",
    do: text

  defp finding_description(finding),
    do: "#{finding["status"]} for #{finding["subject_type"]} #{finding["subject_id"]}."

  defp chain_findings(%{"status" => "intact"}), do: []

  defp chain_findings(chain) do
    problems =
      chain["findings"]
      |> Enum.take(5)
      |> Enum.map_join("; ", &"#{&1["problem"]} at sequence #{&1["sequence"]}")

    for control <- AshEnterprise.Audit.ChainVerifyWorker.evidence_controls() do
      %{
        "uuid" => uuid5("chain-finding:#{control}:#{chain["verified_at"]}"),
        "title" => "#{control}: the audit chain is broken",
        "description" =>
          "The audit chain does not verify: #{length(chain["findings"])} finding(s) (#{problems}).",
        "target" => target(control, "fail", "The audit trail cannot be shown to be untouched.")
      }
    end
  end

  defp target(control_id, reason, remarks) do
    %{
      "type" => "objective-id",
      "target-id" => token(control_id),
      "status" => %{"state" => "not-satisfied", "reason" => reason, "remarks" => remarks}
    }
  end

  # --- helpers ---------------------------------------------------------------

  defp prop(name, value) do
    %{"name" => name, "ns" => @ns, "value" => to_string(value)}
  end

  # A control identifier is an OSCAL token. One that is not (a rule set's own id may
  # start with a digit) is carried with its offending characters replaced.
  @doc false
  def token(id) do
    if Regex.match?(@token, id) do
      id
    else
      cleaned = String.replace(id, ~r/[^\p{L}\p{N}._-]/u, "_")
      if Regex.match?(@token, cleaned), do: cleaned, else: "_" <> cleaned
    end
  end

  defp drop_empty(map), do: Map.reject(map, fn {_key, value} -> value == [] end)

  @doc "A version 5 UUID for `name` (RFC 4122, SHA-1, the URL namespace)."
  def uuid5(name) do
    <<a::48, _version::4, b::12, _variant::2, c::62>> =
      binary_part(:crypto.hash(:sha, Ecto.UUID.dump!(@uuid_namespace) <> name), 0, 16)

    Ecto.UUID.load!(<<a::48, 5::4, b::12, 2::2, c::62>>)
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(at) when is_binary(at), do: at
end
