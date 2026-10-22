# Compiled only when ash_agent_tools is loaded (dev and test): the projection
# behaviour it implements ships in that dependency.
if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Projection) do
  defmodule AshEnterprise.Standards.Projections.FacadeView do
    @moduledoc """
    The code unit plus its module header and the enclosing module's
    `@moduledoc`: what the third-party API question (iron law 20) sees.

    Whether an HTTP call sits in the one facade module for its service is
    said by the module, not by the call, so the question reads the
    module's own description of itself.
    """

    use AshAgentTools.CodeSubjects.Projection, context: [:module_header, :moduledoc]
  end
end
