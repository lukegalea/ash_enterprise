# Compiled only when ash_agent_tools is loaded (dev and test): the projection
# behaviour it implements ships in that dependency.
if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Projection) do
  defmodule AshEnterprise.Standards.Projections.PolicyView do
    @moduledoc """
    The code unit plus its module header and the enclosing module's
    `policies` section: what the two CLAUDE.md questions see
    (`no_forbid_if_for_row_access`, `policy_check_never_queries`).

    A `forbid_if` is read against the policies around it, and a check
    module's header says which check behaviour it implements.
    """

    use AshAgentTools.CodeSubjects.Projection,
      context: [:module_header, {:section, :policies}]
  end
end
