defmodule AshEnterprise.SystemOne.BandTablePublication.CertifyAndPublish do
  @moduledoc """
  A person certifies a calibration run's proposed band table, and the
  table is published: the `CalibrationRun` `:certify_and_publish` act that
  the band-table surface offers (ADR 0061).

  1. Render the run's proposal (`AshJudgments.Calibration.ProposalDmn`)
     over the score inputs of the questions the run calibrated
     (`score_inputs/1`).
  2. Save it as the family's draft definition in the platform tenant,
     where the resolver finds band tables.
  3. Record the certification as the person, in their own tenant: the
     author of record is them (`certified_by` is their email).
  4. Publish through `AshEnterprise.SystemOne.BandTablePublication`, whose
     verifier runs first. A refusal comes back as the action's error, with
     the findings.

  Steps 2 to 4 are one transaction: a refusal leaves no draft and no
  certification, and the run stays in the queue.

  It refuses a run that proposed no table, and a family that already has
  an unpublished draft: publish or discard that one first.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.Banding.Resolver
  alias AshEnterprise.SystemOne.BandTableCertification
  alias AshEnterprise.SystemOne.BandTablePublication
  alias AshJudgments.Calibration.ProposalDmn

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)

    with {:ok, run} <- Ash.get(input.resource, input.arguments.record_id, opts),
         {:ok, proposal} <- proposal(run),
         {:ok, xml} <- render(proposal, run) do
      # The draft, the certification and the publication commit together:
      # a refused table leaves no certification behind, so the run stays
      # in the queue.
      Ash.DataLayer.transaction([Definition, BandTableCertification], fn ->
        certify_and_publish(run, xml, context)
      end)
    end
  end

  defp certify_and_publish(run, xml, context) do
    with {:ok, draft} <- draft(run.family, xml),
         {:ok, certification} <- certify(run, draft, context),
         {:ok, published} <- publish(run, certification) do
      %{
        definition_key: published.key,
        version: published.version,
        certification_id: certification.id
      }
    else
      {:error, error} -> Ash.DataLayer.rollback(BandTableCertification, error)
    end
  end

  @doc """
  The score inputs a run's band table gates on: `"<question>__p_true"` for
  each yes/no question the run calibrated (its `question_hashes`), found
  among this application's declared questions. They are the names
  `AshJudgments.Bridge.Dmn.inputs/2` flattens those questions' answers to.
  """
  @spec score_inputs(map()) :: [String.t()]
  def score_inputs(%{question_hashes: hashes}) do
    hashes = MapSet.new(hashes || [])

    for module <- Application.spec(:ash_enterprise, :modules) || [],
        question <- AshJudgments.Registry.Info.questions(module),
        MapSet.member?(hashes, question.question_hash),
        question.type == AshAi.Evaluate.Noul,
        uniq: true do
      "#{question.name}__p_true"
    end
    |> Enum.sort()
  end

  defp proposal(%{result: :proposed_table, proposed_band_table: %{} = proposal}),
    do: {:ok, proposal}

  defp proposal(_run), do: {:error, "This calibration run proposed no band table."}

  defp render(proposal, run) do
    case score_inputs(run) do
      [] ->
        {:error,
         "None of the questions this run calibrated is a yes/no question this application declares."}

      inputs ->
        case ProposalDmn.render(proposal, score_input: inputs) do
          {:ok, xml} ->
            {:ok, xml}

          {:error, findings} ->
            {:error, "The proposal does not render: " <> Enum.join(findings, "; ")}
        end
    end
  end

  # Band tables are platform baselines: the resolver resolves them in the
  # platform organization.
  defp draft(family, xml) do
    platform = Seeder.seed_platform_organization()
    key = Resolver.band_table_key(family)

    Definition
    |> Ash.Query.filter(key == ^key and status == :draft)
    |> Ash.read_one(authorize?: false, tenant: platform.id)
    |> case do
      {:ok, nil} ->
        Definition.create(%{key: key, name: key, xml: xml},
          authorize?: false,
          tenant: platform.id
        )

      {:ok, _existing} ->
        {:error,
         "The #{family} band table already has an unpublished draft; publish or discard it first."}

      error ->
        error
    end
  end

  defp certify(run, draft, context) do
    BandTableCertification
    |> Ash.Changeset.for_create(
      :record,
      %{
        definition_key: draft.key,
        definition_version: to_string(draft.version),
        content_hash: draft.content_hash,
        family: run.family,
        calibration_run_id: run.id,
        certified_by: to_string(context.actor.email)
      },
      Ash.Context.to_opts(context)
    )
    |> Ash.create()
  end

  # The person's gate is the certification; publishing the verified table
  # is machinery executing that decision (as in the approval loop's test).
  defp publish(run, certification) do
    platform = Seeder.seed_platform_organization()

    case BandTablePublication.publish(
           %{
             family: run.family,
             model_digest: run.model_digest,
             runtime_version: run.runtime_version,
             region: run.region
           },
           certification,
           run,
           actor: SystemActor.process(),
           tenant: platform.id
         ) do
      {:ok, published} ->
        {:ok, published}

      {:error, {:not_verified, findings}} ->
        {:error, "The verifier refused the table: " <> Enum.map_join(findings, "; ", &finding/1)}

      error ->
        error
    end
  end

  defp finding(%{finding: finding} = f), do: "#{finding}#{if f[:message], do: " (#{f.message})"}"
  defp finding(other), do: inspect(other)
end
