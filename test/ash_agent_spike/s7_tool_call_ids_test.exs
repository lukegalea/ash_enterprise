defmodule AshEnterprise.AgentSpike.S7ToolCallIdsTest do
  @moduledoc """
  Spike S7: are the tool-call ids the in-zone model server returns unique
  within a run?

  **Why it matters.** An agent's tool call becomes an invocation keyed
  `run:<run_id>:<step_seq>:<tool_call_id>`. If the server's ids were unique
  per run, the step sequence would be redundant; if they repeat (some
  self-hosted servers number calls `call_0`, `call_1` afresh every turn), the
  step sequence is what keeps two turns' calls apart.

  **Result: holds for the deployed server, and the key does not depend on
  it.** Through ReqLLM, the in-zone runtime (an OpenAI-compatible server)
  returned ids of the form `call_<32 hex>_<index>`: the 32 hex digits are the
  completion's own random id and the index numbers the calls within it, so
  ids are unique across completions and within one. The observation, made
  on 2026-10-23 with a synthetic clinic prompt asking for two parallel
  calls, is recorded in `@observed` and checked below; the live test
  (`--only in_zone_live`, with `S1_GEN_BASE_URL` and `S1_GEN_MODEL` set)
  repeats it against whatever server is configured. The step sequence stays
  in the key regardless: another runtime, or this one after an upgrade, may
  number calls per turn, and the last test shows the key stays unique then.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.AI.Models

  # Tool-call ids from three completions, 2026-10-23, in-zone runtime via ReqLLM.
  @observed [
    ["call_54392a7469b1ab65e25a66ebe06971c9_0", "call_54392a7469b1ab65e25a66ebe06971c9_1"],
    ["call_d829d47c93a5cd0ec0199cca78a8cf1b_0", "call_d829d47c93a5cd0ec0199cca78a8cf1b_1"],
    ["call_3b6f949d3a168e4416fd34c4e0978fb5_0", "call_3b6f949d3a168e4416fd34c4e0978fb5_1"]
  ]

  @id_shape ~r/\Acall_[0-9a-f]{32}_\d+\z/

  defp key(run_id, step_seq, tool_call_id), do: "run:#{run_id}:#{step_seq}:#{tool_call_id}"

  test "the recorded ids have the per-completion shape and never repeat" do
    ids = List.flatten(@observed)
    assert Enum.all?(ids, &(&1 =~ @id_shape))
    assert length(Enum.uniq(ids)) == length(ids)
  end

  test "the invocation key stays unique for a server that numbers calls per turn" do
    run_id = Ecto.UUID.generate()

    # Three turns of a run against a server that restarts at call_0 each turn.
    keys = for step_seq <- 1..3, call <- ["call_0", "call_1"], do: key(run_id, step_seq, call)

    assert length(Enum.uniq(keys)) == length(keys)
    # Without the step sequence the same calls would collide.
    assert length(Enum.uniq(for(_step <- 1..3, call <- ["call_0", "call_1"], do: call))) == 2
  end

  describe "against the configured in-zone runtime" do
    @describetag :in_zone_live
    @describetag timeout: 600_000

    setup do
      base_url = System.get_env("S1_GEN_BASE_URL")
      model = System.get_env("S1_GEN_MODEL")

      if base_url in [nil, ""] or model in [nil, ""] do
        raise "set S1_GEN_BASE_URL and S1_GEN_MODEL to run the in-zone live spike"
      end

      previous = Application.get_env(:ash_enterprise, :ai)
      on_exit(fn -> Application.put_env(:ash_enterprise, :ai, previous || []) end)

      Application.put_env(:ash_enterprise, :ai,
        in_zone_generative: [model: model, base_url: base_url, zone: "synthetic-live-zone"],
        require_in_zone_models: true
      )

      :ok
    end

    test "tool-call ids are unique across completions and within one" do
      target = Models.resolve(Models.default_spec())
      assert target.residency == :in_zone

      tool =
        ReqLLM.Tool.new!(
          name: "list_slots",
          description: "List open appointment slots for one clinician on a day",
          parameter_schema: [
            clinician: [type: :string, required: true],
            day: [type: :string, required: true]
          ],
          callback: fn _args -> {:ok, []} end
        )

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.system("You are a clinic scheduling assistant. Always use tools."),
          ReqLLM.Context.user(
            "Look up the appointment slots for Dr. Avery and Dr. Brooks on Monday. " <>
              "Call the tool once per doctor, in parallel."
          )
        ])

      completions =
        for _ <- 1..3 do
          {:ok, response} =
            Models.call(target, "spike:tool-call-ids", :generate_text, [tools: [tool]], fn opts ->
              ReqLLM.generate_text(target.spec, context, opts)
            end)

          response |> ReqLLM.Response.tool_calls() |> Enum.map(& &1.id)
        end

      ids = List.flatten(completions)
      assert ids != []
      assert length(Enum.uniq(ids)) == length(ids)
    end
  end
end
