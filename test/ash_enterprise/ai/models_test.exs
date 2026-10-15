defmodule AshEnterprise.AI.ModelsTest do
  @moduledoc """
  The in-zone generative profile and the ADR 0042 flow guard
  (`AshEnterprise.AI.Models`): which model a caller gets, that the guard
  refuses a model outside the zone before anything is sent, that an in-zone
  call reaches the profile's host with the profile's key, and that every call
  leaves a structural record and never its content.

  Synthetic prompts only; no model runs (a fake downstream module, or a
  `Req.Test` plug standing in for the in-zone host).
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.AI.Interpreter
  alias AshEnterprise.AI.ModelCall
  alias AshEnterprise.AI.Models
  alias AshEnterprise.AI.Models.GuardedReqLLM
  alias AshEnterprise.AI.Models.OutsideZone
  alias AshEnterprise.AI.ModelsTest.FailingStream
  alias AshEnterprise.Zones.ResidencyPolicy

  @base_url "http://in-zone.test:8000/v1"
  @model "synthetic/in-zone-model"
  @prompt "SYNTHETIC: classify the colour of the sky"

  defmodule FakeReqLLM do
    @moduledoc false
    # Stands in for ReqLLM: reports what it was asked through the test
    # process (registered by name) and answers with fixed usage.
    def generate_object(model, _context, _schema, opts) do
      send(:models_test, {:called, :generate_object, model, opts})
      {:ok, %{object: %{"ok" => true}, usage: %{input_tokens: 11, output_tokens: 7}}}
    end

    def generate_text(model, _context, opts) do
      send(:models_test, {:called, :generate_text, model, opts})
      {:error, %RuntimeError{message: "SYNTHETIC failure text that must not be recorded"}}
    end

    def stream_text(model, _context, opts) do
      send(:models_test, {:called, :stream_text, model, opts})

      {:ok, handle} =
        ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
          %{usage: %{input_tokens: 5, output_tokens: 3}}
        end)

      {:ok,
       %ReqLLM.StreamResponse{
         stream: [ReqLLM.StreamChunk.text("SYNTHETIC")],
         metadata_handle: handle,
         cancel: fn -> :ok end,
         model: model,
         context: ReqLLM.Context.new([])
       }}
    end
  end

  defmodule FailingStream do
    @moduledoc false
    # A stream that opens and then fails while it is read, as a dropped
    # connection to the in-zone host does.
    def stream_text(model, context, opts) do
      {:ok, response} = FakeReqLLM.stream_text(model, context, opts)
      {:ok, %{response | stream: Stream.map([1], fn _ -> raise "SYNTHETIC transport" end)}}
    end
  end

  setup do
    Process.register(self(), :models_test)
    previous = Application.get_env(:ash_enterprise, :ai)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_enterprise, :ai, previous),
        else: Application.delete_env(:ash_enterprise, :ai)
    end)

    :ok
  end

  defp configure(opts) do
    Application.put_env(:ash_enterprise, :ai, opts)
  end

  defp in_zone(extra \\ []) do
    [in_zone_generative: [model: @model, base_url: @base_url, zone: "test-zone"]] ++ extra
  end

  defp calls, do: Ash.read!(ModelCall, authorize?: false)

  describe "resolution" do
    test "without an in-zone profile the default is a hosted model, outside the zone" do
      configure([])

      target = Models.resolve(AshEnterprise.AI.model())
      assert target.residency == :outside_zone
      assert target.profile == "hosted"
    end

    test "with an in-zone profile it is the default, with the profile's transport" do
      configure(in_zone())

      target = Models.resolve(AshEnterprise.AI.model())
      assert target.residency == :in_zone
      assert target.profile == "in_zone_generative"
      assert target.label == "openai:" <> @model
      assert target.zone == "test-zone"
      assert target.req_llm_opts[:base_url] == @base_url
      assert target.req_llm_opts[:reasoning_effort] == :none
      # A runtime that wants no key still gets one sent, so ReqLLM never falls
      # back to OPENAI_API_KEY and hands a vendor's key to the in-zone host.
      assert is_binary(target.req_llm_opts[:api_key])
    end

    test "an explicit interpreter model wins, and a hosted spec is never in-zone" do
      configure(in_zone(interpreter_model: "anthropic:claude-haiku-4-5-20251001"))
      assert Models.resolve(AshEnterprise.AI.model()).residency == :outside_zone

      # The same model id through a catalogue provider resolves to the vendor.
      assert Models.resolve("openai:" <> @model).residency == :outside_zone
    end
  end

  describe "the flow guard" do
    test "off: a hosted call goes through and is recorded without content" do
      configure([])

      assert {:ok, _} =
               GuardedReqLLM.generate_object("anthropic:claude-haiku-4-5-20251001", @prompt, %{},
                 caller: "test.hosted",
                 downstream: FakeReqLLM
               )

      assert_received {:called, :generate_object, _, opts}
      refute Keyword.has_key?(opts, :caller)

      assert [call] = calls()
      assert call.caller == "test.hosted"
      assert call.residency == :outside_zone
      assert call.outcome == :ok
      assert call.operation == :generate_object
      assert {call.input_tokens, call.output_tokens} == {11, 7}
      assert is_binary(call.correlation_id)
      refute inspect(Map.from_struct(call)) =~ "SYNTHETIC"
    end

    test "on: a hosted call is refused before anything is sent, and the refusal recorded" do
      configure(in_zone(require_in_zone_models: true))

      assert_raise OutsideZone, ~r/REQUIRE_IN_ZONE_MODELS/, fn ->
        GuardedReqLLM.generate_object("anthropic:claude-haiku-4-5-20251001", @prompt, %{},
          caller: "test.hosted",
          downstream: FakeReqLLM
        )
      end

      refute_received {:called, _, _, _}
      assert [%{outcome: :refused, residency: :outside_zone}] = calls()
    end

    test "on: a stream outside the zone is refused too" do
      configure(require_in_zone_models: true)

      assert_raise OutsideZone, fn ->
        GuardedReqLLM.stream_text("openrouter:anthropic/claude-haiku-4.5", @prompt,
          downstream: FakeReqLLM
        )
      end

      refute_received {:called, _, _, _}
    end

    test "on: an in-zone call passes, pinned to the profile's host and key" do
      configure(in_zone(require_in_zone_models: true))

      assert {:ok, _} =
               GuardedReqLLM.generate_object(AshEnterprise.AI.model(), @prompt, %{},
                 caller: "test.in_zone",
                 # A caller cannot redirect an in-zone call.
                 base_url: "https://api.example.com/v1",
                 api_key: "caller-key",
                 downstream: FakeReqLLM
               )

      assert_received {:called, :generate_object, _model, opts}
      assert opts[:base_url] == @base_url
      refute opts[:api_key] == "caller-key"
      assert opts[:reasoning_effort] == :none

      assert [%{residency: :in_zone, profile: "in_zone_generative", zone: "test-zone"}] = calls()
    end

    test "a failure is recorded by its class, never its message" do
      configure(in_zone())

      assert {:error, _} =
               GuardedReqLLM.generate_text(AshEnterprise.AI.model(), @prompt,
                 downstream: FakeReqLLM
               )

      assert [call] = calls()
      assert call.outcome == :error
      assert call.error_class == "RuntimeError"
      assert call.caller == "unnamed"
      refute inspect(Map.from_struct(call)) =~ "SYNTHETIC"
    end

    test "a stream is recorded with its usage once it has been read" do
      configure(in_zone(require_in_zone_models: true))

      assert {:ok, response} =
               GuardedReqLLM.stream_text(AshEnterprise.AI.model(), @prompt,
                 caller: "test.stream",
                 downstream: FakeReqLLM
               )

      assert calls() == []
      assert [_chunk] = Enum.to_list(response.stream)

      assert [call] = calls()
      assert call.operation == :stream_text
      assert {call.input_tokens, call.output_tokens} == {5, 3}
    end

    test "a stream that fails or is abandoned mid-read is recorded as incomplete, not ok" do
      configure(in_zone())

      {:ok, failing} =
        GuardedReqLLM.stream_text(AshEnterprise.AI.model(), @prompt, downstream: FailingStream)

      assert_raise RuntimeError, fn -> Enum.to_list(failing.stream) end

      {:ok, abandoned} =
        GuardedReqLLM.stream_text(AshEnterprise.AI.model(), @prompt, downstream: FakeReqLLM)

      assert [_first] = abandoned.stream |> Stream.take(1) |> Enum.to_list()

      assert [%{error_class: "incomplete_stream"}, %{error_class: "incomplete_stream"}] =
               Enum.filter(calls(), &(&1.outcome == :error))
    end
  end

  describe "on the wire" do
    test "an in-zone object call reaches the profile's host as an OpenAI-compatible request" do
      configure(in_zone(require_in_zone_models: true))

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(:models_test, {:request, conn.host, conn.request_path, conn.req_headers, body})

        Req.Test.json(conn, %{
          "id" => "synthetic",
          "object" => "chat.completion",
          "model" => @model,
          "choices" => [
            %{
              "index" => 0,
              "finish_reason" => "tool_calls",
              "message" => %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "call_1",
                    "type" => "function",
                    "function" => %{
                      "name" => "structured_output",
                      "arguments" => ~s({"colour":"blue"})
                    }
                  }
                ]
              }
            }
          ],
          "usage" => %{"prompt_tokens" => 21, "completion_tokens" => 4, "total_tokens" => 25}
        })
      end)

      schema = [colour: [type: :string, required: true]]

      result =
        GuardedReqLLM.generate_object(AshEnterprise.AI.model(), @prompt, schema,
          caller: "test.wire",
          req_http_options: [plug: {Req.Test, __MODULE__}]
        )

      assert_received {:request, "in-zone.test", path, headers, body}
      assert path == "/v1/chat/completions"
      assert {"authorization", "Bearer " <> _} = List.keyfind(headers, "authorization", 0)

      body = Jason.decode!(body)
      assert body["model"] == @model
      assert body["reasoning_effort"] == "none"

      assert {:ok, response} = result
      assert ReqLLM.Response.object(response) == %{"colour" => "blue"}
      assert [%{outcome: :ok, input_tokens: 21, output_tokens: 4}] = calls()
    end
  end

  describe "the helper console" do
    test "under the guard, a hosted interpreter model is refused with the guard's message" do
      configure(
        interpreter_model: "anthropic:claude-haiku-4-5-20251001",
        require_in_zone_models: true
      )

      assert {:error, message} = Interpreter.interpret("SYNTHETIC request", nil, nil)
      assert message =~ "REQUIRE_IN_ZONE_MODELS"
    end
  end

  describe "instrument profiles" do
    test "under the guard, a sub-processor is refused even with a recorded opt-in" do
      opted_in = %Organization{sub_processor_opt_in: true}

      configure([])
      assert ResidencyPolicy.allow?(opted_in, :sub_processor, :any)

      configure(require_in_zone_models: true)
      refute ResidencyPolicy.allow?(opted_in, :sub_processor, :any)
      assert ResidencyPolicy.allow?(opted_in, :in_cluster, :any)
    end

    test "an in-cluster instrument is an in-zone target" do
      assert %{residency: :in_zone} =
               Models.instrument_target(:winnow_generative, "ollama:winnow:e4b", :in_cluster)

      assert %{residency: :outside_zone} =
               Models.instrument_target(:hosted, "openai:gpt-x", :sub_processor)
    end
  end
end
