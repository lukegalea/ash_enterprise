defmodule AshEnterprise.Documents.Paper.Changes.MeasureImpact do
  @moduledoc """
  `measure_impact` on a candidate (a draft `PaperClause`, a draft
  `paper.clause.*` decision `Definition`): measures what it would change in
  the tenant's issued documents (`AshEnterprise.Documents.Paper.Impact`) as the
  acting person, and stores the report on the candidate as `impact_report`.

  A person runs it; nothing measures on read. The report is keyed by the
  candidate's content hash, so the decision that rests on it
  (`AshEnterprise.Documents.Paper.Validations.ImpactMeasured`) can tell a
  report for this version from a stale one. A measurement that could not run
  is stored as an errored report, which refuses that decision.

  The measurement runs here, while the changeset is built, before the write's
  transaction opens: rendering issued documents again takes seconds, and no
  lock is held while it does.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Documents.Paper.Impact

  @impl true
  def change(%Ash.Changeset{valid?: false} = changeset, _opts, _context), do: changeset

  def change(changeset, _opts, context) do
    report = Impact.measure(changeset.data, changeset.tenant, actor: context.actor)
    Ash.Changeset.force_change_attribute(changeset, :impact_report, Impact.stored(report))
  end
end
