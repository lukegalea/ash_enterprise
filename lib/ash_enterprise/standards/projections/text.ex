# Compiled only when ash_agent_tools is loaded (dev and test): the projection
# behaviour it implements ships in that dependency.
if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Projection) do
  defmodule AshEnterprise.Standards.Projections.Text do
    @moduledoc """
    The code unit's own text, with no surrounding context: what the comment
    question (iron law 26) and the house-style questions see.

    Editing anything outside the unit leaves the unit's digest, and so its
    facts, unchanged.
    """

    use AshAgentTools.CodeSubjects.Projection, context: []
  end
end
