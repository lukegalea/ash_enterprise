defmodule AshEnterprise.Ingestion do
  @moduledoc """
  Ingestion foundation (ADR 0010 + ADR 0011, Productivity OS Dogfood epic E1).

  Each ingestion pipeline is an Oban wrapper job (`AshEnterprise.Ingestion.TapWorker`)
  that runs a Meltano/Singer tap and lands its output **immutably** as
  `AshEnterprise.Ingestion.SourceObject` rows: external system, external id, raw
  payload, cursor, fetch time. Canonical projections are deliberately *not* built
  here — they arrive with epic E4 — so this domain is the thin, shared foundation
  for both lineage (E2) and the productivity verticals (E4).

  Meltano is the adapter workbench, not the center (dogfood §11). Nango (ADR 0011)
  owns the provider OAuth edge; the Nango connection id is resolved from an actor's
  linked-account resource by the verticals, never passed as an action argument.
  """

  use Ash.Domain,
    extensions: [AshPhoenix]

  resources do
    resource AshEnterprise.Ingestion.SourceObject
  end
end
