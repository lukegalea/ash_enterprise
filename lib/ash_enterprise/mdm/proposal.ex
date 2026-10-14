defmodule AshEnterprise.Mdm.Proposal do
  @moduledoc """
  AI mapping proposals (MDM-8): from an observed customer schema to a DRAFT
  mapping — never an activation. Activation stays a person's act (the
  mapping's own gate, tested); a proposal is a machine's first draft.

  Two stages:

  1. **Deterministic**: exact name matching between the observed fields and
     the target's public attributes (email, name-like fields). This is the
     floor the plan's acceptance test pins: ≥ the deterministic columns,
     always, with or without an LLM configured.
  2. **LLM seam**: `config :ash_enterprise, :mdm_proposal_llm, {m, f, a}` —
     called with the manifest (target attributes + observed schema + field
     samples) and returning `{:ok, rules}` or `{:error, reason}`. The raw
     output (or the refusal) is retained on the draft's
     `validation_findings["proposal"]` either way: what the model said is
     provenance, not gospel.

  The proposal creates the mapping as a system actor (candidate generation's
  sharp edge, ADR 0017); a person then validates and activates it through
  the ordinary gate.
  """

  @doc "Proposes a draft mapping. Returns {:ok, mapping} or {:error, reason}."
  def propose(tenant, target_resource, observed_schema, opts \\ []) do
    with {:ok, module} <- allowed_target(target_resource) do
      attributes = public_attributes(module)
      samples = Keyword.get(opts, :samples, %{})
      rules = deterministic_rules(attributes, observed_schema)

      {rules, stage, raw} =
        maybe_llm_rules(tenant, target_resource, attributes, observed_schema, samples, rules)

      mapping = create_draft(tenant, target_resource, observed_schema, rules)

      AshEnterprise.Mdm.MappingProposal
      |> Ash.Changeset.for_create(:record, %{
        mapping_id: mapping.id,
        stage: stage,
        raw: raw
      })
      |> Ash.create!(
        tenant: tenant,
        actor: AshEnterprise.Platform.SystemActor.system(),
        authorize?: true
      )

      {:ok, mapping}
    end
  end

  defp allowed_target(target) do
    case AshMdm.Mapping.Validator do
      _ ->
        case Application.get_env(:ash_mdm, :allowed_targets) do
          %{} = allowlist ->
            case Map.get(allowlist, target) do
              nil -> {:error, :target_not_allowed}
              module -> {:ok, module}
            end

          _ ->
            {:error, :no_allowlist}
        end
    end
  end

  defp public_attributes(module) do
    module
    |> Ash.Resource.Info.attributes()
    |> Enum.reject(&(&1.public? == false))
    |> Enum.map(&to_string(&1.name))
  end

  # The deterministic floor: normalized exact matches between observed
  # fields and golden attributes. Always present, LLM or not.
  defp deterministic_rules(attributes, observed_schema) do
    for field <- Map.keys(observed_schema || %{}),
        attr = Enum.find(attributes, &matches?(field, &1)),
        do: %{"path" => field, "target" => attr, "op" => "identity", "args" => %{}}
  end

  defp matches?(field, attr) do
    normalize(field) == normalize(attr) or
      String.contains?(normalize(field), normalize(attr))
  end

  defp normalize(name),
    do: name |> to_string() |> String.downcase() |> String.replace(~r/[^a-z]/, "")

  defp maybe_llm_rules(tenant, target, attributes, observed_schema, samples, deterministic) do
    case Application.get_env(:ash_enterprise, :mdm_proposal_llm, nil) do
      nil ->
        {deterministic, :deterministic_only, %{"llm" => "not configured"}}

      {m, f, a} ->
        manifest = %{
          "tenant" => to_string(tenant),
          "target_resource" => target,
          "target_attributes" => attributes,
          "observed_schema" => observed_schema,
          "samples" => samples
        }

        case apply(m, f, a ++ [manifest]) do
          {:ok, rules} when is_list(rules) ->
            taken = MapSet.new(Enum.map(deterministic, & &1["target"]))

            fresh = Enum.reject(rules, fn rule -> MapSet.member?(taken, rule["target"]) end)

            {deterministic ++ fresh, :llm, %{"rules" => rules}}

          {:error, reason} ->
            # The refusal is retained: what the model would not do is
            # provenance too.
            {deterministic, :llm_refused, %{"reason" => inspect(reason)}}

          other ->
            {deterministic, :llm_invalid, %{"raw" => inspect(other)}}
        end
    end
  end

  defp create_draft(tenant, target, observed_schema, rules) do
    AshEnterprise.Mdm.Mapping
    |> Ash.Changeset.for_create(:draft, %{
      direction: :ingress,
      source: "ai_proposal",
      stream: "proposal",
      target_resource: target,
      field_rules: rules,
      observed_schema: observed_schema
    })
    |> Ash.create!(
      tenant: tenant,
      actor: AshEnterprise.Platform.SystemActor.system(),
      authorize?: true
    )
  end
end
