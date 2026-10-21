defmodule AshEnterprise.Bpmn.Preparations.OfProcess do
  @moduledoc """
  Narrows an instance read to the runs of one process key, whichever version
  each pinned (`AshEnterprise.Process.FlightDiagram.definition_ids/2`).

  An instance carries `definition_id`, not the key, and most pin a platform
  baseline a tenant-scoped join cannot see, so the key is turned into
  definition ids first rather than filtered as `definition.key`.

  The key is the `process:` option (a read fixed to one process, which a
  surface table can name) or the action's `:process` argument.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  alias AshEnterprise.Process.FlightDiagram

  @impl true
  def prepare(query, opts, _context) do
    key = opts[:process] || Ash.Query.get_argument(query, :process)
    ids = FlightDiagram.definition_ids(key, query.tenant)
    Ash.Query.filter(query, definition_id in ^ids)
  end
end
