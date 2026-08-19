defmodule AshEnterpriseWeb.Bpmn.ViewerLive do
  @moduledoc """
  One running process, on the diagram it is actually executing.

  The definition rendered is the one the instance **pinned**, not the latest published — which
  is the point of pinning, and the thing a hand-maintained diagram can never show. Live tokens
  are highlighted where they stand.
  """

  use AshBpmn.Web.ViewerLive, domain: AshEnterprise.Bpmn
end
