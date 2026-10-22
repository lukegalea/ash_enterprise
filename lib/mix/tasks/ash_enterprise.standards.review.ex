# Compiled only when ash_agent_tools is loaded (dev and test), like the
# AshEnterprise.Standards modules it drives.
if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Advisory) do
  defmodule Mix.Tasks.AshEnterprise.Standards.Review do
    @shortdoc "Prints the advisory standards review of a change, as Markdown"
    @moduledoc """
    The advisory review comment for the change between a base revision and
    `HEAD` (`AshEnterprise.Standards.Review`): the iron-laws judge's report,
    unchanged, and what the facts table says about the standards questions
    over the units the change touches.

        mix ash_enterprise.standards.review                 # against origin/main
        mix ash_enterprise.standards.review --base main

    Prints the comment; it posts nothing anywhere. Reads the facts table
    only: no model call, no write, and the exit status does not depend on
    the findings.

    Boots the repo only (iron law 23).
    """

    use Mix.Task

    alias AshEnterprise.Mix.Helpers
    alias AshEnterprise.Standards.Review

    @requirements ["app.config"]

    @impl Mix.Task
    def run(argv) do
      {flags, args, _} = OptionParser.parse(argv, strict: [base: :string])
      root = List.first(args) || File.cwd!()
      base = flags[:base] || "origin/main"

      diff =
        case System.cmd("git", ["-C", root, "diff", "#{base}...HEAD"], stderr_to_stdout: true) do
          {diff, 0} -> diff
          {output, _} -> Mix.raise("git diff #{base}...HEAD failed: #{String.trim(output)}")
        end

      Helpers.boot_repo()
      Mix.shell().info(Review.review(root, diff).markdown)
    end
  end
end
