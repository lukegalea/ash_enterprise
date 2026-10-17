defmodule AshEnterprise.Mdm.People.Seed do
  @moduledoc """
  The people source's configuration, as data (PROD-9): the ingress mapping
  that stages an observation, and the match rule set that scores it. Both
  are ordinary versioned MDM rows; seeding drafts them and activates them
  **as a person** (activation is person-gated, ADR 0054), so `seed!/2` takes
  the person who turns cross-source resolution on for their tenant.

  Idempotent: an active row with the same content is left alone, a draft is
  reused, and a changed definition is a new version that supersedes the
  active one — the way every mapping and rule-set edit works.

  ## The mapping

  Each observation (`AshEnterprise.Mdm.People.Adapter`) maps to the
  person's `name` and `email` (the Person attributes the validator accounts
  for), plus match keys the rule set compares: `email_domain`
  (`regex_extract`), and the observed `person_id`, `system` and
  `linked_account_id`. Rules do not chain, so a name is normalized only as
  far as the scorer's own normalization goes (trimmed, lower-cased); there
  is no whitespace-collapsing or accent-folding operator in the closed
  vocabulary.

  ## The rule set

  Score = Σ weight × contribution / Σ weight, banded by the tenant's DMN band
  table (seed: admit ≥ 0.9, review 0.5–0.9, omit below). The weights are
  chosen so that, under the seed bands:

  | Evidence | Score | Band |
  |---|---|---|
  | same address (the row's own person; the same address seen by two sources) | 0.9–1.0 | admit |
  | same name and same email domain, different address | 0.55 (0.65 with shared context) | review |
  | name similar (Jaro ≥ ~0.89) and shared context | 0.5–0.55 | review |
  | same name alone | 0.45 | omit |

  Nothing reaches admit without the address: the three name and context
  rules together weigh 0.65. Thresholds are the band table's, never these
  weights' — a calibrated table moves the bands, and the table above is only
  what the seed does.

  **Shared context** is the one piece of evidence the package cannot
  express: whether the two people are in the same events or conversations,
  or share someone they meet or write with. `ash_mdm`'s comparators are
  `exact` and `fuzzy` over fields; there is no set-overlap comparator, and
  co-occurrence is a fact about the pair, not about either side. So the
  people matcher computes it (`AshEnterprise.Mdm.People.Pipeline`) and hands
  it to an `exact` rule as a field, `co_occurrence: "shared"`, which the
  mapping sets on the staged side with `constant`. It is a host-computed pair
  feature, not a new operator; the package-level fix is an `overlap`
  comparator over list fields.
  """

  require Ash.Query

  alias AshEnterprise.Mdm.{Mapping, MatchRuleSet, People}

  @field_rules [
    %{"path" => "person_id", "target" => "person_id", "op" => "identity", "args" => %{}},
    %{"path" => "name", "target" => "name", "op" => "identity", "args" => %{}},
    %{"path" => "email", "target" => "email", "op" => "identity", "args" => %{}},
    %{
      "path" => "email",
      "target" => "email_domain",
      "op" => "regex_extract",
      "args" => %{"pattern" => "@([^@\\s]+)$", "group" => 1}
    },
    %{"path" => "system", "target" => "system", "op" => "identity", "args" => %{}},
    %{
      "path" => "linked_account_id",
      "target" => "linked_account_id",
      "op" => "identity",
      "args" => %{}
    },
    %{
      "target" => "co_occurrence",
      "op" => "constant",
      "args" => %{"value" => "shared"},
      "because" => "the staged side of the matcher's shared-context pair feature"
    }
  ]

  @observed_schema %{
    "person_id" => %{},
    "name" => %{},
    "email" => %{},
    "system" => %{},
    "linked_account_id" => %{}
  }

  @rules [
    %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 3.5},
    %{
      "name" => "name_and_domain",
      "kind" => "exact",
      "fields" => ["name", "email_domain"],
      "weight" => 1.0
    },
    %{
      "name" => "name_similar",
      "kind" => "fuzzy",
      "field" => "name",
      "algorithm" => "jaro",
      "weight" => 4.5
    },
    %{
      "name" => "shared_context",
      "kind" => "exact",
      "fields" => ["co_occurrence"],
      "weight" => 1.0
    }
  ]

  # The survivor's own values win; the absorbed record fills its gaps.
  @survivorship %{"default" => "non_null"}

  def field_rules, do: @field_rules
  def rules, do: @rules

  @doc "Drafts (when needed) and activates the people mapping and rule set as `person`."
  @spec seed!(term(), struct()) :: %{mapping: struct(), rule_set: struct()}
  def seed!(tenant, person) do
    %{mapping: seed_mapping!(tenant, person), rule_set: seed_rule_set!(tenant, person)}
  end

  defp seed_mapping!(tenant, person) do
    hash = AshMdm.Mapping.ContentHash.hash!(@field_rules)

    case People.mapping(tenant) do
      %{content_hash: ^hash} = active ->
        active

      active ->
        draft =
          Mapping
          |> Ash.Query.filter(
            source == ^People.mapping_source() and stream == ^People.mapping_stream() and
              status in [:draft, :validated] and content_hash == ^hash
          )
          |> Ash.Query.sort(version: :desc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(tenant: tenant, authorize?: false)

        (draft || draft_mapping!(tenant, active))
        |> validate_mapping!(tenant)
        |> Ash.Changeset.for_update(:activate, %{activation_note: "people sweep (PROD-9)"},
          tenant: tenant,
          actor: person
        )
        |> Ash.update!(tenant: tenant, actor: person)
    end
  end

  defp draft_mapping!(tenant, nil) do
    Mapping
    |> Ash.Changeset.for_create(
      :draft,
      %{
        direction: :ingress,
        source: People.mapping_source(),
        stream: People.mapping_stream(),
        target_resource: People.golden_resource(),
        field_rules: @field_rules,
        observed_schema: @observed_schema
      },
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!(tenant: tenant, authorize?: false)
  end

  defp draft_mapping!(tenant, active) do
    Mapping
    |> Ash.Changeset.for_create(
      :create_version,
      %{
        from_mapping_id: active.id,
        direction: :ingress,
        source: People.mapping_source(),
        stream: People.mapping_stream(),
        target_resource: People.golden_resource(),
        field_rules: @field_rules,
        observed_schema: @observed_schema
      },
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!(tenant: tenant, authorize?: false)
  end

  defp validate_mapping!(%{status: :validated} = mapping, _tenant), do: mapping

  defp validate_mapping!(mapping, tenant) do
    validated =
      mapping
      |> Ash.Changeset.for_update(:validate, %{}, tenant: tenant, authorize?: false)
      |> Ash.update!(tenant: tenant, authorize?: false)

    case validated do
      %{status: :validated} ->
        validated

      other ->
        raise ArgumentError,
              "the people mapping did not validate: #{inspect(other.validation_findings)}"
    end
  end

  defp seed_rule_set!(tenant, person) do
    # Compared by the rules themselves: the package stamps a rule set's
    # `content_hash` from `field_rules`, which a rule set does not have, so
    # every rule set carries the same hash.
    hash = AshMdm.Mapping.ContentHash.hash!(@rules)
    same? = &(AshMdm.Mapping.ContentHash.hash!(&1.rules) == hash)

    active = People.rule_set(tenant)

    if active && same?.(active) do
      active
    else
      draft =
        MatchRuleSet
        |> Ash.Query.filter(golden_resource == ^People.rule_set_key() and status == :draft)
        |> Ash.Query.sort(version: :desc)
        |> Ash.read!(tenant: tenant, authorize?: false)
        |> Enum.find(same?)

      (draft || draft_rule_set!(tenant))
      |> Ash.Changeset.for_update(:activate, %{}, tenant: tenant, actor: person)
      |> Ash.update!(tenant: tenant, actor: person)
    end
  end

  defp draft_rule_set!(tenant) do
    MatchRuleSet
    |> Ash.Changeset.for_create(
      :draft,
      %{golden_resource: People.rule_set_key(), rules: @rules, survivorship: @survivorship},
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!(tenant: tenant, authorize?: false)
  end
end
