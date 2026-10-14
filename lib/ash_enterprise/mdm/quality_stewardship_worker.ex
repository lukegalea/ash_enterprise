defmodule AshEnterprise.Mdm.QualityStewardshipWorker do
  @moduledoc """
  The production trigger for findings→stewardship (MDM-7): after a
  projector drain, every noncompliant MDM finding opens its claimable
  `mdm.quality_review` task (`QualityReview.start_stewardship_for_findings!/1`).

  Sweeps per tenant on the `:mdm` queue. Idempotent: a golden already
  running an instance is skipped by the start path, so re-runs cost one
  indexed read per tenant.
  """

  use Oban.Worker,
    queue: :mdm,
    max_attempts: 3

  alias AshEnterprise.Compliance.Resources.Finding
  alias AshEnterprise.Mdm.QualityReview

  @impl true
  def perform(_job) do
    Finding
    |> Ash.Query.select([:organization_id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.organization_id)
    |> Enum.uniq()
    |> Enum.each(&QualityReview.start_stewardship_for_findings!/1)

    :ok
  end
end
