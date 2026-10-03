defmodule AshEnterprise.SystemOne.Banding.CalibrationSampleWriter do
  @moduledoc """
  The live-accumulation wiring (S1-62): when a person's human verdict
  lands, the labelled pair is appended to the family's calibration slot.

  The §7.3 basis routing decides what feeds calibration: `labelling`,
  `review_task` and `audit_sample` all feed the family's slot (a label is
  a label); an `override` does not — an override is a correction to
  live work, not calibration data (ADR 0047 point 8: reviewed data is
  biased, and its bias belongs to the eval lane, not to the thresholds).

  The slot fields come from the VERDICT's referenced judgment (the ledger
  row): family, question hash, model digest, runtime version and region —
  the run key minus the eval set. The pair's digests travel; the gold
  label itself never does (§8.1: labelled text stays in the zone's
  evaluation store).

  Replay safety: the write runs in an after_action hook, and AshEvents
  strips hooks during replay — a replayed verdict appends nothing. Within
  live traffic the sample fragment's `:unique_observation` identity is
  the second lock.
  """

  use Ash.Resource.Change

  alias AshEnterprise.SystemOne.CalibrationSample
  alias AshEnterprise.SystemOne.Judgment
  alias AshJudgments.Registry.Canonical

  @feeding_bases [:labelling, :review_task, :audit_sample]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, verdict ->
      if verdict.basis in @feeding_bases do
        append_sample!(verdict, changeset)
      end

      {:ok, verdict}
    end)
  end

  defp append_sample!(verdict, changeset) do
    # The verdict cites the judgment it corrects; reading it (digests and
    # slot fields only) is provenance for the label the person just gave,
    # not a widening — the row id was already the person's input.
    judgment = Ash.get!(Judgment, verdict.judgment_id, authorize?: false)

    CalibrationSample
    |> Ash.Changeset.for_create(
      :record,
      %{
        family: judgment.family,
        question_hash: judgment.question_hash,
        model_digest: judgment.model_digest,
        runtime_version: judgment.runtime_version,
        region: judgment.region,
        tenant: tenant_of(changeset),
        observation_id: verdict.judgment_id,
        pair_digest:
          Canonical.digest(%{
            "observation_id" => verdict.judgment_id,
            "gold_label" => verdict.human_value
          }),
        gold_label_digest: Canonical.digest(verdict.human_value)
      },
      actor: changeset.context[:private][:actor] || changeset.context[:actor],
      tenant: changeset.tenant
    )
    |> Ash.create!()

    :ok
  end

  defp tenant_of(changeset) do
    case changeset.tenant do
      t when is_binary(t) -> t
      %{id: id} -> id
      _other -> nil
    end
  end
end
