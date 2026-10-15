defmodule AshEnterprise.Mdm.Banding do
  @moduledoc """
  The MDM band table (ADR 0041/0053): a candidate's match score goes
  through the versioned DMN decision `mdm:match_bands` — never a literal —
  and comes out `admit | review | omit`.

  `publish_seed_bands!/1` publishes the wide-review seed into a tenant
  (or the platform organization, which tenants then fork). Bands tighten
  only through the calibration loop, exactly like the System One band
  tables; this module never reads a threshold.

  With `:banding_id` set to the candidate id, the evaluation is idempotent
  per candidate (System One's AC-4 posture).
  """

  require Ash.Query

  alias AshEnterprise.Decisions
  alias AshEnterprise.Decisions.Definition

  @definition_key "mdm:match_bands"
  @bands ~w(admit review omit)

  defp promote_band(outputs) when is_binary(outputs), do: outputs
  defp promote_band(outputs) when is_map(outputs), do: outputs["Band"] || outputs[:Band]
  defp promote_band(_), do: nil

  @doc "Publishes the wide-review seed table into `tenant` (idempotent per key+tenant)."
  def publish_seed_bands!(tenant) do
    xml = File.read!(Path.join(:code.priv_dir(:ash_enterprise), "dmn/mdm_match_bands.dmn"))

    existing =
      Definition
      |> Ash.Query.filter(key == ^@definition_key)
      |> Ash.read_one!(tenant: tenant, authorize?: false)

    case existing do
      %{status: :published} = definition ->
        definition

      nil ->
        definition =
          Definition
          |> Ash.Changeset.for_create(
            :create,
            %{key: @definition_key, name: "MDM match bands", xml: xml},
            tenant: tenant,
            authorize?: false
          )
          |> Ash.create!(tenant: tenant, authorize?: false)

        if definition.errors in [nil, []] do
          :ok
        else
          raise "mdm_match_bands did not compile: #{inspect(definition.errors)}"
        end

        Definition.publish!(definition, tenant: tenant, authorize?: false)

      other ->
        raise "mdm:match_bands exists in status #{other.status}; bands tighten via calibration, not re-seeding"
    end
  end

  @doc """
  Bands one match score. Returns `{:ok, band_atom}` where band ∈
  `admit | review | omit`, or `{:error, reason}` — an unevaluatable table
  is an error, never a silent admit.
  """
  def band(score, tenant, opts \\ []) do
    opts =
      Keyword.merge(opts, tenant: tenant, record: true)

    with {:ok, result} <- Decisions.evaluate(@definition_key, %{"score" => score}, opts),
         # A single-output decision promotes: outputs may be the bare value
         # or a map keyed by the output name.
         band when band in @bands <- promote_band(result.outputs) do
      {:ok, String.to_existing_atom(band)}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_band_output, other}}
    end
  end
end
