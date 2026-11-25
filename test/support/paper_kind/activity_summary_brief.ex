defmodule AshEnterprise.Test.Paper.ActivitySummaryBrief do
  @moduledoc """
  The SYNTHETIC `activity_summary_brief` kind: the same subject and the same
  source as `AshEnterprise.Test.Paper.ActivitySummary`, a one-page schema, no
  clause and no requirement.
  """

  use AshEnterprise.Documents.Paper.Kind

  alias AshEnterprise.Documents.Paper.Kind
  alias AshEnterprise.Test.Paper.ActivitySummary

  @impl Kind
  def key, do: "activity_summary_brief"

  @impl Kind
  def schema, do: __MODULE__.Schema

  @impl Kind
  def default_theme, do: "carlito"

  @impl Kind
  def source(subject, opts), do: ActivitySummary.totals(subject, opts)
end
