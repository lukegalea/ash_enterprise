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

  The draft and its proposal row are written as `opts[:actor]` — by default
  the system actor (candidate generation's sharp edge, ADR 0017); a surface
  a person clicks passes that person, so their grants on `Mapping` and
  `MappingProposal` decide and a refusal writes nothing. Either way a person
  then validates and activates the draft through the ordinary gate. The
  draft and its proposal row are written together or not at all.
  """

  alias AshEnterprise.Mdm.{Mapping, MappingProposal}
  alias AshEnterprise.Platform.SystemActor

  @doc """
  Proposes a draft mapping. Returns {:ok, mapping} or {:error, reason}.

  Options: `:samples` (field samples, masked before any LLM sees them),
  `:actor` (who writes the draft; the system actor when omitted).
  """
  def propose(tenant, target_resource, observed_schema, opts \\ []) do
    with {:ok, module} <- allowed_target(target_resource) do
      attributes = public_attributes(module)
      samples = Keyword.get(opts, :samples, %{})
      rules = deterministic_rules(attributes, observed_schema)

      {rules, stage, raw} =
        maybe_llm_rules(tenant, target_resource, attributes, observed_schema, samples, rules)

      write = [tenant: tenant, actor: Keyword.get(opts, :actor, SystemActor.system())]

      Ash.transaction([Mapping, MappingProposal], fn ->
        write_draft(target_resource, observed_schema, rules, {stage, raw}, write)
      end)
    end
  end

  # Inside the transaction: a refused proposal row rolls the draft back.
  defp write_draft(target, observed_schema, rules, {stage, raw}, write) do
    with {:ok, mapping} <- create_draft(target, observed_schema, rules, write),
         {:ok, _proposal} <- record_proposal(mapping, stage, raw, write) do
      mapping
    else
      {:error, error} -> Ash.DataLayer.rollback([Mapping, MappingProposal], error)
    end
  end

  defp record_proposal(mapping, stage, raw, write) do
    MappingProposal
    |> Ash.Changeset.for_create(:record, %{mapping_id: mapping.id, stage: stage, raw: raw}, write)
    |> Ash.create()
  end

  defp allowed_target(target) do
    case Application.get_env(:ash_mdm, :allowed_targets) do
      %{} = allowlist -> allowlisted(allowlist, target)
      _ -> {:error, :no_allowlist}
    end
  end

  defp allowlisted(allowlist, target) do
    case Map.get(allowlist, target) do
      nil -> {:error, :target_not_allowed}
      module -> {:ok, module}
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
        # Values never leave the zone: samples are masked to their types.
        masked =
          Map.new(samples || %{}, fn {field, value} ->
            {field, if(is_binary(value), do: "string", else: type_of(value))}
          end)

        manifest = %{
          "tenant" => to_string(tenant),
          "target_resource" => target,
          "target_attributes" => attributes,
          "observed_schema" => observed_schema,
          "samples" => masked
        }

        m
        |> apply(f, a ++ [manifest])
        |> llm_outcome(deterministic)
    end
  end

  defp llm_outcome({:ok, rules}, deterministic) when is_list(rules) do
    taken = MapSet.new(Enum.map(deterministic, & &1["target"]))

    fresh = Enum.reject(rules, fn rule -> MapSet.member?(taken, rule["target"]) end)

    {deterministic ++ fresh, :llm, %{"rules" => rules}}
  end

  # The refusal is retained: what the model would not do is provenance too.
  defp llm_outcome({:error, reason}, deterministic),
    do: {deterministic, :llm_refused, %{"reason" => inspect(reason)}}

  defp llm_outcome(other, deterministic),
    do: {deterministic, :llm_invalid, %{"raw" => inspect(other)}}

  defp type_of(value) do
    cond do
      is_integer(value) -> "integer"
      is_float(value) -> "float"
      is_boolean(value) -> "boolean"
      is_binary(value) -> "string"
      true -> "unknown"
    end
  end

  defp create_draft(target, observed_schema, rules, write) do
    Mapping
    |> Ash.Changeset.for_create(
      :draft,
      %{
        direction: :ingress,
        source: "ai_proposal",
        stream: "proposal",
        target_resource: target,
        field_rules: rules,
        observed_schema: observed_schema
      },
      write
    )
    |> Ash.create()
  end
end
