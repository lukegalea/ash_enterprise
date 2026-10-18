defmodule Mix.Tasks.AshEnterprise.Assistant.Eval do
  @shortdoc "Asks the in-zone model the assistant's eval set and prints a scorecard"

  @moduledoc """
  Runs the assistant's eval set (`AshEnterprise.Test.AssistantEval`, PROD-46)
  against the **real in-zone model**, on a SYNTHETIC fixture tenant, and
  prints a scorecard: tool-choice accuracy, argument validity, citation
  coverage, key facts, surfaces and proposals, latency p50/p95.

      S1_GEN_BASE_URL=http://… S1_GEN_MODEL=… mix ash_enterprise.assistant.eval
      mix ash_enterprise.assistant.eval --only calendar_tomorrow,board_tasks

  Runs under `MIX_ENV=test` (the eval set and its fixtures live in
  `test/support`), inside one sandboxed transaction on the test database that
  is rolled back at the end: the synthetic tenant, threads, answers and model
  call records are gone afterwards. Every model call goes through the
  runner's ADR 0042 guard with `REQUIRE_IN_ZONE_MODELS` on, so only the
  in-zone profile can be asked.

  Prints counts and rates only. The full results — each case's tool calls
  and its (synthetic) answer — go to `tmp/assistant_eval/<timestamp>.json`,
  which is gitignored.

  Boots only what a run needs (iron law #23): the Repo, ReqLLM's HTTP pool,
  and the application's PubSub (notifiers on the seeded resources broadcast
  on it). No Oban, no endpoint, no projectors.
  """

  use Mix.Task

  alias AshEnterprise.Canonical.Projections.ZoneAdmission
  alias AshEnterprise.Mix.Helpers

  @requirements ["app.config"]
  @zone "assistant-eval-zone"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [only: :string])

    unless Mix.env() == :test do
      Mix.raise(
        "Run it as MIX_ENV=test mix ash_enterprise.assistant.eval " <>
          "(the eval set lives in test/support)."
      )
    end

    base_url = System.get_env("S1_GEN_BASE_URL", "")
    model = System.get_env("S1_GEN_MODEL", "")

    if base_url == "" or model == "" do
      Mix.raise("Set S1_GEN_BASE_URL and S1_GEN_MODEL to the in-zone runtime.")
    end

    # Warnings only: the test env logs every query at debug, parameters and
    # all, and this task prints counts, never content.
    Logger.configure(level: :warning)

    configure!(base_url, model)
    boot!()

    # test/support modules: named at runtime, since they exist only under test.
    eval = Module.concat([AshEnterprise, Test, AssistantEval])
    fixtures = Module.concat([AshEnterprise, Test, AssistantFixtures])

    # One transaction, rolled back when this process exits; shared, so
    # anything the run spawns writes inside it too.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AshEnterprise.Repo, ownership_timeout: :infinity)
    Ecto.Adapters.SQL.Sandbox.mode(AshEnterprise.Repo, {:shared, self()})

    ctx = fixtures.tenant!()
    fixture = eval.seed!(ctx)
    cases = select(eval.cases(fixture), opts[:only])

    Mix.shell().info("asking #{length(cases)} case(s) of the in-zone model…")
    results = eval.run(ctx, cases)
    card = eval.scorecard(results)

    path = Path.join(["tmp", "assistant_eval", "#{System.os_time(:second)}.json"])
    eval.write!(path, results, card, %{model: model, cases: length(cases)})

    Enum.each(eval.lines(card), fn line -> Mix.shell().info(line) end)
    Mix.shell().info("results: #{path}")
  end

  defp select(cases, nil), do: cases

  defp select(cases, only) do
    ids = String.split(only, ",", trim: true)
    Enum.filter(cases, &(&1.id in ids))
  end

  # The profile as runtime.exs would set it outside test, plus the guard on and
  # the canonical store in the profile's zone. No scripted downstream.
  defp configure!(base_url, model) do
    Application.put_env(:ash_enterprise, :ai,
      in_zone_generative: [
        model: model,
        base_url: base_url,
        api_key: {:system, "S1_GEN_API_KEY"},
        reasoning_effort: System.get_env("S1_GEN_REASONING_EFFORT", "none"),
        zone: @zone
      ],
      require_in_zone_models: true
    )

    Application.put_env(:ash_enterprise, ZoneAdmission, zone: @zone)
    Application.delete_env(:ash_enterprise, AshEnterprise.Assistant.Runner)
  end

  defp boot! do
    Helpers.boot_repo()
    Helpers.load_domain_resources()
    {:ok, _} = Application.ensure_all_started(:req_llm)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: AshEnterprise.PubSub) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
