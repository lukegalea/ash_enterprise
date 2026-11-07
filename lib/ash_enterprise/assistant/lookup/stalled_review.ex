defmodule AshEnterprise.Assistant.Lookup.StalledReview do
  @moduledoc """
  The reviews that have waited too long, as the assistant shows them: one row saying
  how many there are, listing each with a ref to cite, and the view it put on the
  person's screen.

  Computed, never stored: `stalled_reviews` is a manual read
  (`AshEnterprise.Assistant.Lookups.StalledReviews`) of `HumanTask.stalled` as the
  person, behind the zone gate. The same read is the stalled-reviews surface
  (`/app/reviews/stalled`), so what the chat shows can be reached without it.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:stalled_reviews],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :shown, :string, public?: true
    attribute :count, :integer, public?: true
    attribute :reviews, {:array, :map}, public?: true
    attribute :surface, :map, public?: true
    attribute :page, :string, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    read :stalled_reviews do
      description "Reviews and other tasks waiting on people for more than two days."
      manual Lookups.StalledReviews
    end
  end

  # It reads, and puts the same read on the person's screen: it changes nothing.
  effects do
    action :stalled_reviews,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end
