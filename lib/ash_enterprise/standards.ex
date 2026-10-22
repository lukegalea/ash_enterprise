# Compiled only when ash_agent_tools is loaded: it is a dev and test
# dependency, so production has neither this domain nor its resource. The
# router's dev MCP route is guarded by `:dev_routes`, which is false in test;
# the standards must compile in test too, so the guard is the dependency's
# own presence (the optional-dependency pattern ash_agent_tools uses itself).
if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Fragment) do
  defmodule AshEnterprise.Standards do
    @moduledoc """
    Our engineering standards as declared questions over our own code
    (AST-138).

    The standards stay where they are written: the CLAUDE.md
    non-negotiables, the iron laws (ash_agent_tools'
    `usage-rules/iron-laws.md`; how this repository applies them is
    `docs/IRON-LAWS.md`) and `docs/HOUSE-STYLE.md`. This domain holds the seventeen confirmed
    questions about them, declared on `AshEnterprise.Standards.CodeUnit`,
    and the machinery that asks them:

      * `AshEnterprise.Standards.Questions`: each question's clause, the
        projection it sees and which answers are violations.
      * `AshEnterprise.Standards.Candidates`: the deterministic rung that
        decides which units a question is asked about.
      * `AshEnterprise.Standards.Standing`: the standing job, run on `main`
        after a merge. It finds the units whose facts are missing or stale,
        judges them and routes each answer through the banding step.
      * `AshEnterprise.Standards.Review`: the advisory review comment for a
        change. The iron-laws judge's report is in it unchanged.

    Model answers here are advisory: nothing in this domain fails a build.

    Registered in no `ash_domains` list (`validate_config_inclusion?:
    false`), because production does not compile it; the resource is not
    persisted, so codegen has nothing to see.
    """

    use Ash.Domain, otp_app: :ash_enterprise, validate_config_inclusion?: false

    resources do
      resource AshEnterprise.Standards.CodeUnit do
        define :scan_code_units, action: :scan, args: [:root]
      end
    end

    @subject_type "AshEnterprise.Standards.CodeUnit"

    @doc """
    The subject type every standards fact is written and read under: the
    resource the questions are declared on.
    """
    @spec subject_type() :: String.t()
    def subject_type, do: @subject_type

    @doc """
    The composite subject term the facts table stores for a code unit:
    `AshAgentTools.CodeSubjects.subject_term/2` with this domain's type.
    """
    @spec subject_term(map()) :: %{String.t() => String.t()}
    def subject_term(subject),
      do: AshAgentTools.CodeSubjects.subject_term(subject, type: @subject_type)
  end
end
