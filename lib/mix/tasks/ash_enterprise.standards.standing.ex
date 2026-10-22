# Compiled only when ash_agent_tools is loaded (dev and test), like the
# AshEnterprise.Standards modules it drives.
if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Standing) do
  defmodule Mix.Tasks.AshEnterprise.Standards.Standing do
    @shortdoc "Runs the standards standing job over a checkout (assess, judge, admit)"
    @moduledoc """
    The standards standing job (`AshEnterprise.Standards.Standing`), meant
    for a checkout of `main` after each merge.

        # What would be judged, with no model call and no write
        mix ash_enterprise.standards.standing --dry-run

        # Judge and admit the pending units, as the oban system actor
        mix ash_enterprise.standards.standing --tenant <organization uuid>

        # One question, at most 20 units, over another checkout
        mix ash_enterprise.standards.standing ../checkout --tenant <uuid> \\
          --question hs6_no_novelty_claims --limit 20

        # The candidate units whose facts say they break their standard
        mix ash_enterprise.standards.standing --violations

    Prints JSON. Judging calls the `:winnow_gpu` profile through the in-zone
    transport, so its endpoint variables must be set; `--dry-run` and
    `--violations` read the facts table only.

    Boots the repo and the HTTP client only (iron law 23): no Oban, no
    endpoint, no projectors.
    """

    use Mix.Task

    alias AshEnterprise.Mix.Helpers
    alias AshEnterprise.Standards.{Questions, Standing}

    @requirements ["app.config"]

    @switches [
      tenant: :string,
      question: :keep,
      limit: :integer,
      repository: :string,
      dry_run: :boolean,
      violations: :boolean
    ]

    @impl Mix.Task
    def run(argv) do
      {flags, args, _} = OptionParser.parse(argv, strict: @switches)
      root = List.first(args) || File.cwd!()

      Helpers.boot_repo()
      opts = options(flags)

      report =
        cond do
          flags[:violations] ->
            %{violations: Enum.map(Standing.violations(root, opts), &violation/1)}

          flags[:dry_run] ->
            %{pending: pending(Standing.assess(root, opts))}

          true ->
            judge(root, flags, opts)
        end

      Mix.shell().info(Jason.encode!(report, pretty: true))
    end

    defp options(flags) do
      questions =
        case Keyword.get_values(flags, :question) do
          [] -> nil
          names -> Enum.map(names, &question_name!/1)
        end

      [
        repository: flags[:repository],
        questions: questions,
        limit: flags[:limit],
        tenant: flags[:tenant]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    end

    # Question names are a closed list: an unknown one fails loud rather
    # than minting an atom.
    defp question_name!(name) do
      Enum.find(Questions.names(), &(Atom.to_string(&1) == name)) ||
        Mix.raise(
          "unknown question #{inspect(name)}; known: #{Enum.join(Questions.names(), ", ")}"
        )
    end

    defp judge(root, flags, opts) do
      unless flags[:tenant], do: Mix.raise("--tenant is required to judge (or pass --dry-run)")
      {:ok, _} = Application.ensure_all_started(:req_llm)

      results = Standing.run(root, opts)

      %{
        judged: length(results),
        results:
          Enum.map(results, fn result ->
            result
            |> Map.take([:question, :subject_id, :location, :reason, :observation_id])
            |> Map.put(:outcome, outcome(result.result))
          end)
      }
    end

    defp pending(by_question) do
      Map.new(by_question, fn {name, pending} ->
        {name,
         %{
           count: length(pending),
           units: Enum.map(pending, fn {s, reason} -> %{location: s.location, reason: reason} end)
         }}
      end)
    end

    defp violation(v), do: %{question: v.question, clause: v.clause, location: v.subject.location}

    defp outcome({:ok, %{band: band}}), do: %{band: band}
    defp outcome({:refusal, refusal}), do: %{refusal: refusal.reason}
    defp outcome({:error, error}), do: %{error: Exception.message(Ash.Error.to_ash_error(error))}
  end
end
