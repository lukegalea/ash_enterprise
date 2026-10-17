defmodule AshEnterprise.Assistant.InZoneLiveTest do
  @moduledoc """
  The assistant against the REAL in-zone runtime, on synthetic data only.

  Excluded by default; run it with the profile in the environment:

      S1_GEN_BASE_URL=… S1_GEN_MODEL=… mix test --only in_zone_live \\
        test/ash_enterprise/assistant/in_zone_live_test.exs

  It seeds a synthetic tenant (invented events, threads and people on
  `example.test`), asks a few questions through `AshEnterprise.Assistant.Runner`
  — guard on, every call recorded — and prints the tools each answer used,
  its step count and its latency. Nothing real is read and nothing leaves
  the zone: the only model it can reach is the profile's.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.AI.ModelCall
  alias AshEnterprise.Assistant.{Runner, Thread}
  alias AshEnterprise.Canonical.Projections.ZoneAdmission
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.DailyFixtures, as: D

  @moduletag :in_zone_live
  @moduletag timeout: 900_000

  @questions [
    "What meetings do I have tomorrow, and who is attending?",
    "Which email threads still need a reply from me?",
    "Who have I exchanged the most messages with in the last 30 days?",
    "What did Quinn Synthetic say about the SYNTHETIC launch checklist?"
  ]

  setup do
    base_url = System.get_env("S1_GEN_BASE_URL")
    model = System.get_env("S1_GEN_MODEL")

    if base_url in [nil, ""] or model in [nil, ""] do
      raise "set S1_GEN_BASE_URL and S1_GEN_MODEL to run the in-zone live test"
    end

    previous = Map.new([:ai, ZoneAdmission], &{&1, Application.get_env(:ash_enterprise, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:ash_enterprise, key, value),
          else: Application.delete_env(:ash_enterprise, key)
      end
    end)

    Application.put_env(:ash_enterprise, :ai,
      in_zone_generative: [model: model, base_url: base_url, zone: "synthetic-live-zone"],
      require_in_zone_models: true
    )

    Application.put_env(:ash_enterprise, ZoneAdmission, zone: "synthetic-live-zone")
    :ok
  end

  test "answers synthetic questions with the read tools" do
    ctx = F.tenant!()
    seed!(ctx)

    for question <- @questions do
      {:ok, thread} = Thread.start("SYNTHETIC live", actor: ctx.actor, tenant: ctx.tenant)
      started = System.monotonic_time(:millisecond)

      result =
        Runner.run(thread: thread, actor: ctx.actor, tenant: ctx.tenant, question: question)

      elapsed = System.monotonic_time(:millisecond) - started

      {status, turn} =
        case result do
          {:ok, turn} -> {:complete, turn}
          {:error, reason, turn} -> {reason, turn}
        end

      tools = Enum.map((turn && turn.tool_calls["calls"]) || [], &{&1["name"], &1["count"]})

      IO.puts("""

      Q: #{question}
        status #{inspect(status)} · #{turn && turn.iterations} model calls · #{elapsed} ms
        tools #{inspect(tools)}
        cited #{length((turn && turn.refs) || [])} refs
        A: #{turn && turn.content}
      """)
    end

    calls = Ash.read!(ModelCall, authorize?: false)
    durations = calls |> Enum.map(& &1.duration_ms) |> Enum.reject(&is_nil/1) |> Enum.sort()

    IO.puts(
      "model calls: #{length(calls)} · all in-zone: #{Enum.all?(calls, &(&1.residency == :in_zone))} " <>
        "· outcomes #{inspect(Enum.frequencies_by(calls, & &1.outcome))} · ms #{inspect(durations)}"
    )

    assert Enum.all?(calls, &(&1.residency == :in_zone))
  end

  defp seed!(ctx) do
    quinn = D.person!(ctx, "quinn@example.test", "Quinn Synthetic")
    _ = quinn

    D.event!(ctx, "SYNTHETIC roadmap sync", 60 * 24 + 60, 30,
      organizer: {"quinn@example.test", "Quinn Synthetic"}
    )

    D.event!(ctx, "SYNTHETIC vendor onboarding", 60 * 24 + 180, 45)
    D.event!(ctx, "SYNTHETIC one-on-one", 120, 30)

    D.conversation!(
      ctx,
      "gmail",
      "SYNTHETIC launch checklist",
      "Can you confirm the SYNTHETIC launch checklist by Friday? — Quinn"
    )

    D.conversation!(
      ctx,
      "gmail",
      "SYNTHETIC invoice question",
      "Is the SYNTHETIC invoice approved?"
    )

    D.conversation!(ctx, "slack", "SYNTHETIC #ops", "SYNTHETIC deploy finished cleanly.")
  end
end
