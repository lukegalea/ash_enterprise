# Compiled only when ash_agent_tools is loaded (dev and test): the projection
# behaviour it implements ships in that dependency.
if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Projection) do
  defmodule AshEnterprise.Standards.Projections.ModuleHeader do
    @moduledoc """
    The code unit plus its module header: the `defmodule` line and its `use`,
    `import`, `alias`, `require` and `@behaviour` statements.

    The header says what kind of module the unit sits in (a LiveView, an Oban
    worker) and what its aliases point at, which the iron-law questions 06,
    08, 09 and 11 and house-style question HS-9 need to read the unit.
    """

    use AshAgentTools.CodeSubjects.Projection, context: [:module_header]
  end
end
