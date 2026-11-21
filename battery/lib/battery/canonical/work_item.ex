defmodule Battery.Canonical.WorkItem do
  @moduledoc """
  The work-tracking vocabulary over the canonical task: a facade that
  renames the task's words — `state` for `status`, `effort_minutes` for
  `estimated_minutes` — and writes through it, one source action per write.
  The task's internal notes are not part of this vocabulary, and its legacy
  reference and period are unplaced. The task's policy decides who may read
  or change anything, because every read and write runs as the caller.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  facade do
    source Battery.Canonical.Task

    map :id, from: :id
    map :title, from: :title

    decode(:state, from: :status, values: %{open: :new, done: :finished, cancelled: :cancelled})

    map :effort_minutes, from: :estimated_minutes

    hide(:internal_notes, because: "Not part of this vocabulary.")
    defer(:legacy_ref)
    defer(:valid_at)

    write(:finish, via: :complete, sets: [state: :finished])
    write(:set_estimate, via: :set_estimate, accepts: [:effort_minutes])
    write(:retitle, via: :retitle, accepts: [:title])
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true

    attribute :state, :atom,
      public?: true,
      constraints: [one_of: [:new, :finished, :cancelled]]

    attribute :effort_minutes, :integer, public?: true
  end
end
