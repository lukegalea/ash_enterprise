defmodule Mix.Tasks.AshEnterprise.Assistant.Eval do
  @shortdoc "Asks the in-zone model the assistant's eval set and prints a scorecard"

  @moduledoc """
  Runs the assistant's eval set (`AshEnterprise.Test.AssistantEval`, PROD-46)
  against the **real in-zone model**, on a SYNTHETIC fixture tenant, and
  prints a scorecard: tool-choice accuracy, argument validity, citation
  coverage, key facts, surfaces and proposals, latency p50/p95.

      S1_GEN_BASE_URL=http://… S1_GEN_MODEL=… mix ash_enterprise.assistant.eval
      mix ash_enterprise.assistant.eval --only calendar_tomorrow,board_tasks

      # Also grade the answers against the agent_reply_style family
      S1_OLLAYA_GPU_BASE_URL=http://… mix ash_enterprise.assistant.eval \\
        --judge-model-version winnow:e4b --judge-model-digest sha256:… \\
        --judge-runtime-version ollaya-…

  Runs under `MIX_ENV=test` (the eval set and its fixtures live in
  `test/support`), inside one sandboxed transaction on the test database that
  is rolled back at the end: the synthetic tenant, threads, answers and model
  call records are gone afterwards. Each answer is a run of the assistant
  agent, published in the fixture tenant and stepped here as its jobs would
  step it; every model call goes through the ADR 0042 guard with
  `REQUIRE_IN_ZONE_MODELS` on, so only the in-zone profile can be asked.

  ## Grading the answers

  Given the judge's identity (all three `--judge-*` flags), the task
  grades each answer through `AshEnterprise.Quality.Grader` in the run's
  synthetic evaluation tenant, the tenant the cases ran in, and prints
  `AshEnterprise.Quality.Gate.family_report/3` for the
  `agent_reply_style` family beside the scorecard
  (`AshEnterprise.Test.AssistantEval.grade/2`). The judge is the
  `:winnow_gpu` profile, so `S1_OLLAYA_GPU_BASE_URL` must be set too.
  Every judgment records the identity given, so a person's verdict on it
  can feed the calibration slot it keys; give the digest and runtime
  version the judge runtime reports.

  Without the flags nothing is judged, and the task says so: the family
  is unmeasured, not passed. Given some flags but not all three, it stops
  before asking anything.

  A pass or a fail needs a certified, published band table for the
  family. The report reads the platform's published table, which does
  not carry its certification, so until one is supplied the report reads
  `unmeasured` with the reason `not certified`. The run's ledger rows go
  with the rolled-back transaction, like everything else it writes.

  Prints counts and rates only. The full results — each case's tool calls
  and its (synthetic) answer — go to `tmp/assistant_eval/assistant-eval-<timestamp>.json`,
  which is gitignored.

  Boots only what a run needs (iron law #23): the Repo, ReqLLM's HTTP pool,
  the application's PubSub (notifiers on the seeded resources broadcast on
  it) and Oban in test's manual mode, so a run's start can enqueue its step
  without anything running it. No endpoint, no projectors, no queues.
  """

  use Mix.Task

  alias AshEnterprise.Canonical.Projections.ZoneAdmission
  alias AshEnterprise.Mix.Helpers

  @requirements ["app.config"]
  @zone "assistant-eval-zone"

  @switches [
    only: :string,
    judge_model_version: :string,
    judge_model_digest: :string,
    judge_runtime_version: :string
  ]

  @instrument_flags [
    model_version: :judge_model_version,
    model_digest: :judge_model_digest,
    runtime_version: :judge_runtime_version
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)
    instrument = instrument!(opts)

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

    if instrument && System.get_env("S1_OLLAYA_GPU_BASE_URL", "") == "" do
      Mix.raise("Grading calls the :winnow_gpu judge: set S1_OLLAYA_GPU_BASE_URL.")
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
    _version = fixtures.published!(ctx)
    fixture = eval.seed!(ctx)
    cases = select(eval.cases(fixture), opts[:only])

    Mix.shell().info("asking #{length(cases)} case(s) of the in-zone model…")
    results = eval.run(ctx, cases)
    card = eval.scorecard(results)

    run_id = "assistant-eval-#{System.os_time(:second)}"

    if instrument do
      Mix.shell().info("grading #{length(results)} answer(s) against agent_reply_style…")
    end

    # Without an instrument, grade/2 judges nothing and reports the family
    # unmeasured.
    grade =
      eval.grade(results,
        run_id: run_id,
        instrument: instrument,
        tenant: ctx.tenant,
        actor: ctx.actor
      )

    path = Path.join(["tmp", "assistant_eval", "#{run_id}.json"])

    eval.write!(path, results, card, %{
      model: model,
      cases: length(cases),
      judgments: eval.grade_summary(grade)
    })

    Enum.each(eval.lines(card) ++ eval.grade_lines(grade), fn line ->
      Mix.shell().info(line)
    end)

    Mix.shell().info("results: #{path}")
  end

  @doc false
  # The judge's identity from the --judge-* flags: nil when none is given;
  # all three or the task stops, as a judgment without them can never
  # become a calibration sample.
  @spec instrument!(keyword()) :: map() | nil
  def instrument!(opts) do
    given =
      for {key, flag} <- @instrument_flags,
          opts[flag] not in [nil, ""],
          into: %{},
          do: {key, opts[flag]}

    cond do
      given == %{} ->
        nil

      map_size(given) == length(@instrument_flags) ->
        given

      true ->
        Mix.raise(
          "Grading needs all of --judge-model-version, --judge-model-digest and " <>
            "--judge-runtime-version; got only " <>
            Enum.map_join(
              Map.keys(given),
              ", ",
              &"--judge-#{String.replace(to_string(&1), "_", "-")}"
            )
        )
    end
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
    Application.delete_env(:ash_enterprise, AshEnterprise.Execution.AgentRuntime)
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

    # A run's start enqueues its first step. Under test's `testing: :manual` that
    # only writes the job: the harness steps each run itself.
    case Oban.start_link(Application.fetch_env!(:ash_enterprise, Oban)) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
