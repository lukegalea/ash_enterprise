defmodule Mix.Tasks.AshEnterprise.SystemOne.SealJudgedState do
  @shortdoc "Seals the judged text of judgments still awaiting a verdict (S1-98)"
  @moduledoc """
  The S1-98 backfill (`AshEnterprise.SystemOne.JudgedState.Backfill`): seals
  the text a model judged on each observation that still awaits a person's
  verdict and was recorded before the text was sealed, so the verdicts
  screen can show it.

      # What a run would seal: writes nothing, opens no scope
      mix ash_enterprise.system_one.seal_judged_state

      # Seal, reading code units from the deployed checkout
      mix ash_enterprise.system_one.seal_judged_state --apply --root /path/to/checkout

      # One tenant only
      mix ash_enterprise.system_one.seal_judged_state --tenant <organization uuid>

  Each subject is found again and projected as the judge projected it, and
  its text is sealed only when its digest equals the one the judgment
  recorded. Prints counts only, never text:

    * `awaiting`: observations considered;
    * `sealed`: sealed (on a dry run, would be sealed);
    * `changed`: the subject's text has changed since it was judged, so
      nothing is sealed;
    * `unresolved`: the subject cannot be found again;
    * `shredded`: the erasure scope is shredded.

  A second run finds nothing to do. Boots only the repo (iron law #23).
  """

  use Mix.Task

  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.SystemOne.JudgedState.Backfill

  @requirements ["app.config"]

  @switches [apply: :boolean, root: :string, tenant: :string]

  @impl Mix.Task
  def run(argv) do
    {flags, _args, _invalid} = OptionParser.parse(argv, strict: @switches)
    apply? = Keyword.get(flags, :apply, false)

    Helpers.boot_repo()
    Helpers.load_domain_resources()

    counts =
      Backfill.run(
        apply?: apply?,
        root: Keyword.get(flags, :root),
        tenant: Keyword.get(flags, :tenant)
      )

    Mix.shell().info(
      if(apply?, do: "Sealed judged text.", else: "Dry run: nothing written.") <>
        Enum.map_join([:awaiting, :sealed, :changed, :unresolved, :shredded], "", fn key ->
          "\n  #{key}: #{Map.fetch!(counts, key)}"
        end)
    )
  end
end
