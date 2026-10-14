defmodule AshEnterprise.Mdm.LlmProposer do
  @moduledoc """
  The default `:mdm_proposal_llm` implementation (MDM-8): one structured
  `ReqLLM.generate_object/4` call over the proposal manifest, returning
  field rules for the observed schema.

  The manifest carries everything the model sees — target attributes,
  observed schema, field samples — and nothing else (no tenant ids, no row
  values beyond the samples the operator attached). The output is field
  rules only; the proposal still drafts, validates and activates through
  the ordinary person gates.

  Tests inject a fake MFA through `:mdm_proposal_llm` — the same pattern
  as the registry judge's transport override. No model runs in a test.

  The model comes from the AshJudgments profile `:mdm_proposal`; until an
  operator configures that profile, the proposer errors and the proposal
  degrades to the deterministic floor.
  """

  # The JSON schema `generate_object` constrains the model with: an array
  # of {path, target, op} field rules from the closed vocabulary.
  @schema %{
    "type" => "object",
    "properties" => %{
      "rules" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string"},
            "target" => %{"type" => "string"},
            "op" => %{
              "type" => "string",
              "enum" => AshMdm.Mapping.Evaluator.ops() |> Enum.map(&to_string/1)
            },
            "because" => %{"type" => "string"}
          },
          "required" => ["path", "target", "op"]
        }
      }
    },
    "required" => ["rules"]
  }

  @doc "Generates field rules for the manifest via the resolved model."
  def generate(manifest) when is_map(manifest) do
    with {:ok, spec, opts} <- resolve() do
      prompt = build_prompt(manifest)

      # The transport returns the raw JSON the model produced.
      case AshEnterprise.SystemOne.QuestionProposal.Transport.ReqLLM.generate(
             spec,
             opts,
             @schema,
             prompt
           ) do
        {:ok, raw_json} when is_binary(raw_json) ->
          with {:ok, %{"rules" => rules}} <- Jason.decode(raw_json) do
            {:ok, rules}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The judgment profile machinery resolves the model spec + transport opts;
  # the transport is the same ReqLLM adapter the question proposals use.
  defp resolve do
    profile = Application.get_env(:ash_enterprise, :mdm_proposal_profile, :mdm_proposal)
    AshEnterprise.SystemOne.QuestionProposal.Transport.ReqLLM.resolve(profile)
  end

  defp build_prompt(manifest) do
    """
    Map the customer's observed schema onto our golden-record attributes.

    Target attributes: #{inspect(manifest["target_attributes"])}
    Observed schema: #{inspect(manifest["observed_schema"])}
    Field samples (types only — values never leave the zone): #{inspect(manifest["samples"])}

    Return one rule per observed field you can map: path = the observed
    field, target = the golden attribute, op = an identity or trim from the
    allowed ops. Do not invent fields or attributes.
    """
  end

  defp extract_rules(response) do
    case ReqLLM.Response.object(response) do
      %{"rules" => rules} when is_list(rules) -> rules
      _ -> []
    end
  end
end
