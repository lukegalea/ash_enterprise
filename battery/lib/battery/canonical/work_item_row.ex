defmodule Battery.Canonical.WorkItemRow do
  @moduledoc """
  The second hop: a label view over the work-item facade, for consumers
  that want an id and a name and nothing else. It reads the work-item as
  its caller, which reads the task as its caller — one chain, read hop by
  hop — and stores nothing of its own. The work-item's state is not part
  of this view, and its effort is unplaced.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  facade do
    source Battery.Canonical.WorkItem

    map :id, from: :id
    map :label, from: :title

    hide(:state, because: "A row is an id and a label; the state is not part of this view.")
    defer(:effort_minutes)
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :label, :string, public?: true
  end
end
