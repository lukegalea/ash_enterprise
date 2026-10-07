defmodule Mix.Tasks.AshEnterprise.SystemOne.ReplayFacts do
  @shortdoc "Replays recorded fact decisions through the temporal materialiser (AST-149 §5.2)"
  @moduledoc """
  The facts temporal-swap's data migration (design note §5.2): facts are
  derived, so the cut-over replays the RECORDED decisions in
  `effective_at` order through the temporal materialiser — never SQL
  translation. The legacy table is archived by rename in the migration;
  this task rebuilds the new table's periods afterwards.

      # From the audit event log (the recorded decision sequence)
      mix ash_enterprise.system_one.replay_facts

      # Inspect without writing
      mix ash_enterprise.system_one.replay_facts --dry-run

      # From a JSONL file of decisions instead (one decision per line)
      mix ash_enterprise.system_one.replay_facts --file decisions.jsonl

  The event log IS the decision sequence: every materialiser write on the
  facts table was audited, so `:materialise` creates become `:admitted`
  decisions and `:supersede` updates become `:omitted` decisions at their
  `occurred_at`. The replay-equivalence property (AST-148) is what makes
  the rebuild correct. Writes nothing on `--dry-run`.

  Boots only the repo (iron law #23): no Oban, no endpoint, no
  projectors.
  """

  use Mix.Task

  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.SystemOne.FactReplay

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [file: :string, dry_run: :boolean])

    Helpers.boot_repo()
    # The event log's :atom columns deserialize only when the resources
    # that own the atoms are loaded.
    Helpers.load_domain_resources()

    {source, decisions} =
      case opts[:file] do
        nil ->
          {:ok, decisions} = FactReplay.decisions_from_event_log([])
          {"the audit event log", decisions}

        path ->
          {path, read_jsonl(path)}
      end

    by_result = Enum.frequencies_by(decisions, & &1.result)

    span =
      decisions
      |> Enum.map(& &1.effective_at)
      |> case do
        [] -> "no recorded decisions"
        instants -> "#{Enum.min(instants, DateTime)} … #{Enum.max(instants, DateTime)}"
      end

    Mix.shell().info(
      "\n#{length(decisions)} recorded decision(s) from #{source} (#{span})" <>
        Enum.map_join(by_result, "", fn {result, n} -> "\n  #{result}: #{n}" end)
    )

    if opts[:dry_run] do
      Mix.shell().info("\nDry run — nothing written.")
    else
      {:ok, tally} = FactReplay.replay(decisions)

      verdicts =
        tally
        |> Map.drop([:replayed])
        |> Enum.reject(fn {_verdict, n} -> n == 0 end)
        |> Enum.map_join(", ", fn {verdict, n} -> "#{verdict}: #{n}" end)

      Mix.shell().info("\nReplayed #{tally.replayed} decision(s) — #{verdicts}.")
    end
  end

  defp read_jsonl(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
    |> Enum.map(&atomize_keys/1)
  end

  # JSONL decisions arrive string-keyed; the materialiser reads atom keys.
  # to_existing_atom: the decision vocabulary is the materialiser's own
  # frozen contract — an unknown key fails loud, never mints an atom.
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {String.to_existing_atom(k), if(is_map(v), do: atomize_keys(v), else: v)}
    end)
  end
end
