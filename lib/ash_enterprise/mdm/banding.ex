defmodule AshEnterprise.Mdm.Banding do
  @moduledoc """
  The MDM band table (ADR 0041/0054): a candidate's match score goes
  through the versioned DMN decision `mdm:match_bands` — never a literal —
  and comes out `admit | review | omit`.

  `publish_seed_bands!/1` publishes the wide-review seed into a tenant
  (or the platform organization, which tenants then fork). Bands tighten
  only through the calibration loop, exactly like the System One band
  tables; this module never reads a threshold. The seed and an earned
  table read the same input, the score as a decimal string, so the score
  goes in one way whichever is published.

  With `:banding_id` set to the candidate id, the evaluation is idempotent
  per candidate (System One's AC-4 posture).
  """

  require Ash.Query

  alias AshEnterprise.Decisions
  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Mdm.MatchObservation
  alias AshJudgments.Calibration.ProposalDmn

  @definition_key "mdm:match_bands"
  @bands ~w(admit review omit)

  defp promote_band(outputs) when is_binary(outputs), do: outputs

  defp promote_band(outputs) when is_map(outputs),
    do: outputs["Band"] || outputs[:Band] || outputs["band"] || outputs[:band]

  defp promote_band(_), do: nil

  @doc """
  Publishes the wide-review seed table into `tenant`, and returns the
  published definition.

  Idempotent: when the latest published `mdm:match_bands` is the current
  seed, or a table calibration earned, it is returned unchanged. When it is
  an older seed (one that declared the score a number, say), the current
  seed is published as a new version: running instances never pin a
  decision, so the next banding reads it. A table calibration earned is
  never replaced by a seed. A pending draft raises: bands tighten through
  calibration, not re-seeding.
  """
  def publish_seed_bands!(tenant) do
    xml = seed_bands_xml()

    case latest_published(tenant) do
      %Definition{} = published ->
        if earned?(published) or same_xml?(published.xml, xml) do
          published
        else
          publish_seed!(xml, tenant)
        end

      nil ->
        publish_seed!(xml, tenant)
    end
  end

  defp latest_published(tenant) do
    Definition
    |> Ash.Query.filter(key == ^@definition_key and status == :published)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
  end

  defp publish_seed!(xml, tenant) do
    if draft?(tenant) do
      raise "mdm:match_bands has an unpublished draft; bands tighten via calibration, not re-seeding"
    end

    definition =
      Definition
      |> Ash.Changeset.for_create(
        :create,
        %{key: @definition_key, name: "MDM match bands", xml: xml},
        tenant: tenant,
        authorize?: false
      )
      |> Ash.create!(tenant: tenant, authorize?: false)

    if definition.errors not in [nil, []] do
      raise "mdm_match_bands did not compile: #{inspect(definition.errors)}"
    end

    Definition.publish!(definition, tenant: tenant, authorize?: false)
  end

  defp draft?(tenant) do
    Definition
    |> Ash.Query.filter(key == ^@definition_key and status == :draft)
    |> Ash.exists?(tenant: tenant, authorize?: false)
  end

  # A table the calibration loop earned is one `ProposalDmn` rendered: its
  # thresholds read back. The seed's rules carry no earned threshold.
  defp earned?(%Definition{xml: xml}), do: match?({:ok, _}, ProposalDmn.thresholds(xml))

  # The definition stores its XML trimmed (Ash trims string attributes).
  defp same_xml?(stored, xml), do: String.trim(stored) == String.trim(xml)

  @doc """
  Bands one match score. Returns `{:ok, band_atom}` where band ∈
  `admit | review | omit`, or `{:error, reason}` — an unevaluatable table
  is an error, never a silent admit.

  The score goes in as the match question's yes probability,
  `matches_the_golden__p_true`, as its decimal string: the input both the
  seed and a table calibration earned read, through `number(...)`.
  """
  def band(score, tenant, opts \\ []) do
    opts = Keyword.merge(opts, tenant: tenant, record: true)

    with {:ok, result} <-
           Decisions.evaluate(@definition_key, %{score_input() => score_string(score)}, opts),
         # A single-output decision promotes: outputs may be the bare value
         # or a map keyed by the output name.
         band when band in @bands <- promote_band(result.outputs) do
      {:ok, String.to_existing_atom(band)}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_band_output, other}}
    end
  end

  @doc """
  The input name the MDM band tables read: the match question's
  `<question>__p_true`, the name `AshJudgments.Bridge.Dmn.inputs/2`
  flattens its answer to, and so the one the certify act renders an earned
  table over.
  """
  def score_input, do: "#{MatchObservation.question().name}__p_true"

  defp score_string(%Decimal{} = score), do: Decimal.to_string(score, :normal)
  defp score_string(score) when is_float(score), do: Float.to_string(score)
  defp score_string(score) when is_integer(score), do: Integer.to_string(score)
  defp score_string(score) when is_binary(score), do: score

  # Sobelow reads `@sobelow_skip` out of the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see AshEnterprise.Audit.Export).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  # The path is a constant under this application's own priv dir — no caller
  # input reaches it. Skipped here, by name, so any change that lets a caller
  # choose the file is the thing a reviewer should question.
  @sobelow_skip ["Traversal.FileModule"]
  defp seed_bands_xml do
    File.read!(Path.join(:code.priv_dir(:ash_enterprise), "dmn/mdm_match_bands.dmn"))
  end
end
