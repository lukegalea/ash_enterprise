defmodule AshEnterprise.Compliance.Seeds do
  @moduledoc """
  Seeds the KYC compliance vertical slice (ADR 0035) for one organization:
  the whole control plane the projector needs before it may evaluate.

    * a catalog and controls for the KYC gaps,
    * the global mandatory rule set revision (from
      `AshEnterprise.Compliance.KycRules`), validated → approved → **active**,
    * the non-waivable floor revision (from
      `AshEnterprise.Compliance.KycNonWaivableRules`), active,
    * a tenant strengthening revision (from
      `AshEnterprise.Compliance.KycStrengtheningRules`), active,
    * a tailoring profile whose revision refines the MFA rule,
    * a tenant policy set carrying the profile,
    * one bounded waiver of the periodic-review rule,
    * revision "2" of the baseline (`AshEnterprise.Compliance.KycRulesV2`),
      seeded as a **draft** — activating it is the replay test's job,
    * the compiled, activated `PolicyBundle`.

  Idempotent where it matters: rule set revisions, catalog versions and
  profile revisions are keyed by content hash and unique constraint, so
  re-running compiles a fresh bundle only when the layers changed. The waiver
  is skipped when one is already in force for the rule.

  Called by `mix ash_enterprise.compliance.seed` and by the compliance test
  suite's setup; that dual use is why the logic lives in the domain rather
  than in the Mix task.
  """

  require Logger
  require Ash.Query

  alias AshCompliance.Resources.{
    Catalog,
    CatalogVersion,
    Control,
    ControlMapping,
    PolicyOverride,
    Profile,
    ProfileRevision,
    RuleSetRevision,
    TenantPolicySet
  }

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc "Seeds the program for one organization. Returns the active bundle."
  def seed(organization_id) do
    catalog = seed_catalog(organization_id)
    seed_controls(organization_id, catalog)
    seed_rule_set(organization_id)
    seed_non_waivable_rule_set(organization_id)
    seed_strengthening_rule_set(organization_id)
    seed_profile(organization_id)
    seed_waiver(organization_id)
    seed_v2_rule_set(organization_id)

    bundle =
      AshCompliance.Domain.compile_policy_bundle!(%{organization_id: organization_id},
        authorize?: false
      )

    bundle = AshCompliance.Domain.activate_policy_bundle!(bundle, authorize?: false)

    Logger.info("Compliance program seeded; bundle #{bundle.content_hash} is active.")

    {:ok, bundle}
  end

  # --- the pieces ---------------------------------------------------------------

  defp seed_catalog(organization_id) do
    catalog =
      case Catalog
           |> Ash.Query.filter(organization_id == ^organization_id and name == "KYC Baseline")
           |> Ash.read_one!(authorize?: false) do
        nil ->
          Ash.create!(Catalog, %{
            organization_id: organization_id,
            name: "KYC Baseline",
            description: "The KYC control baseline for the compliance slice.",
            oscal_uuid: "00000000-0000-0000-0000-00000000c7c7"
          })

        catalog ->
          catalog
      end

    # The unique (catalog, content_hash) index makes a re-seed fail here;
    # that failure is the no-op, so swallow it.
    case Ash.create(CatalogVersion, %{
           catalog_id: catalog.id,
           version: "1",
           source: "seeded from AshEnterprise.Compliance.KycRules",
           content_hash: content_hash("catalog-v1"),
           published_at: now()
         }) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end

    catalog
  end

  @gaps [
    {"kyc.identity", "Identity confirmation"},
    {"kyc.contact", "Reachable contact"},
    {"kyc.jurisdiction", "Supported jurisdiction"},
    {"kyc.sanctions", "Sanctions screening"},
    {"kyc.sanctions_floor", "Sanctions screening (non-waivable floor)"},
    {"kyc.enhanced_review", "Enhanced review"},
    {"kyc.welcome", "Onboarding review"},
    {"kyc.review", "Periodic review"},
    {"kyc.remediations", "Remediation closure"},
    {"kyc.accounts", "Account balance freeze"},
    {"kyc.tier", "Risk-tier review"},
    {"kyc.migration", "E-mail domain migration"},
    {"kyc.mfa", "MFA enrolment"}
  ]

  defp seed_controls(organization_id, catalog) do
    Enum.each(@gaps, fn {gap, title} ->
      case Ash.create(Control, %{
             organization_id: organization_id,
             catalog_id: catalog.id,
             control_id: gap,
             title: title
           }) do
        {:ok, control} ->
          {:ok, _} =
            Ash.create(AshCompliance.Resources.ControlRevision, %{
              control_id: control.id,
              version: "1",
              statement: title,
              status: :active
            })

          {:ok, _} =
            Ash.create(ControlMapping, %{
              organization_id: organization_id,
              gap: gap,
              control_id: gap
            })

        {:error, _} ->
          # Seeded before; the unique constraint on (organization, control_id)
          # is the idempotence.
          :ok
      end
    end)
  end

  defp seed_rule_set(organization_id) do
    seed_revision(organization_id,
      name: "kyc-baseline",
      revision: "1",
      layer: :global_mandatory,
      source_module: AshEnterprise.Compliance.KycRules,
      activate?: true
    )
  end

  defp seed_non_waivable_rule_set(organization_id) do
    seed_revision(organization_id,
      name: "kyc-non-waivable",
      revision: "1",
      layer: :global_non_waivable,
      source_module: AshEnterprise.Compliance.KycNonWaivableRules,
      activate?: true
    )
  end

  defp seed_strengthening_rule_set(organization_id) do
    seed_revision(organization_id,
      name: "kyc-strengthening",
      revision: "1",
      layer: :tenant_strengthening,
      source_module: AshEnterprise.Compliance.KycStrengtheningRules,
      activate?: true
    )
  end

  # The replay-testable rule change, seeded but NOT activated: revision 2 of
  # the baseline (`kyc.email_domain_migrated` at `:high`) enters the lifecycle
  # as a draft, and driving validate -> approve -> activate -> retire(1) is
  # the replay test's job, not a seed's. The draft is still visible on the
  # rule-sets surface, which is the point of seeding it.
  defp seed_v2_rule_set(organization_id) do
    seed_revision(organization_id,
      name: "kyc-baseline",
      revision: "2",
      layer: :global_mandatory,
      source_module: AshEnterprise.Compliance.KycRulesV2,
      activate?: false
    )
  end

  # One (organization, name, revision) key, content-hashed and immutable: a
  # re-seed finds the row and moves on. `source_module` compiles to the bundle
  # here, at seed time -- the revision stores the JSON, not a reference, so
  # editing the module later changes nothing already seeded.
  defp seed_revision(organization_id, opts) do
    name = Keyword.fetch!(opts, :name)
    revision_number = Keyword.fetch!(opts, :revision)
    layer = Keyword.fetch!(opts, :layer)
    module = Keyword.fetch!(opts, :source_module)
    bundle = module.__bundle__()

    revision =
      case RuleSetRevision
           |> Ash.Query.filter(
             organization_id == ^organization_id and name == ^name and
               revision == ^revision_number
           )
           |> Ash.read_one!(authorize?: false) do
        nil ->
          Ash.create!(RuleSetRevision, %{
            organization_id: organization_id,
            name: name,
            revision: revision_number,
            layer: layer,
            combining: :deny_overrides,
            source_module: inspect(module),
            rules_json: AshRules.Ir.encode!(bundle),
            content_hash: bundle.content_hash
          })

        revision ->
          revision
      end

    if opts[:activate?] && revision.status != :active do
      activate(revision)
    end

    revision
  end

  defp seed_profile(organization_id) do
    profile =
      case Profile
           |> Ash.Query.filter(organization_id == ^organization_id and name == "kyc-tailoring")
           |> Ash.read_one!(authorize?: false) do
        nil ->
          Ash.create!(Profile, %{
            organization_id: organization_id,
            name: "kyc-tailoring"
          })

        profile ->
          profile
      end

    operations = [
      # Refines the STRENGTHENING rule — refining a mandatory rule is
      # refused by the compiler, which is exactly the check to exercise.
      %{"op" => "refine", "target" => "kyc.mfa_required", "severity" => "high"}
    ]

    revision =
      case ProfileRevision
           |> Ash.Query.filter(profile_id == ^profile.id and version == "1")
           |> Ash.read_one!(authorize?: false) do
        nil ->
          Ash.create!(ProfileRevision, %{
            profile_id: profile.id,
            version: "1",
            source: "seeded tailoring",
            operations: operations,
            content_hash: content_hash("profile-v1")
          })

        revision ->
          # Revisions are immutable by design; when the seeded operations move
          # on (they did once, mid-development), the correction is a corrected
          # row behind the same version key. Direct repo write: the package
          # ships no update action for revisions, deliberately.
          if revision.operations != operations do
            AshEnterprise.Repo.update!(Ecto.Changeset.change(revision, operations: operations))

            revision
          else
            revision
          end
      end

    # Attach to the tenant's policy set — creating it here when the compile
    # flow has not made one yet, and updating the ids when it has.
    case TenantPolicySet
         |> Ash.Query.filter(organization_id == ^organization_id)
         |> Ash.read_one!(authorize?: false) do
      nil ->
        {:ok, _} =
          Ash.create(TenantPolicySet, %{
            organization_id: organization_id,
            name: "compliance-program",
            profile_revision_ids: [revision.id]
          })

      policy_set ->
        AshEnterprise.Repo.update!(
          Ecto.Changeset.change(policy_set, profile_revision_ids: [revision.id])
        )
    end

    revision
  end

  defp seed_waiver(organization_id) do
    existing =
      AshCompliance.Resources.PolicyOverride
      |> Ash.Query.filter(
        organization_id == ^organization_id and kind == :waive and
          rule_id == "kyc.review_required"
      )
      |> Ash.Query.filter(is_nil(expires_at) or expires_at > ^now())
      |> Ash.read_one!(authorize?: false)

    if existing do
      Logger.info("Waiver for kyc.review_required already in force; skipping.")
      :ok
    else
      {:ok, _} =
        Ash.create(PolicyOverride, %{
          organization_id: organization_id,
          kind: :waive,
          rule_id: "kyc.review_required",
          reason:
            "Legacy estate onboarding window: periodic review waived while the " <>
              "e-mail domain migration completes",
          approver: "compliance-office",
          approved_at: now(),
          starts_at: now(),
          expires_at: DateTime.add(now(), 30 * 86_400, :second),
          compensating_controls: ["manual-review-queue"]
        })

      :ok
    end
  end

  defp activate(revision) do
    revision
    |> Ash.Changeset.for_update(:validate)
    |> Ash.update!(authorize?: false)
    |> Ash.Changeset.for_update(:approve)
    |> Ash.update!(authorize?: false)
    |> Ash.Changeset.for_update(:activate)
    |> Ash.update!(authorize?: false)
  end

  defp content_hash(term) do
    :crypto.hash(:sha256, inspect(term)) |> Base.encode16(case: :lower)
  end
end
