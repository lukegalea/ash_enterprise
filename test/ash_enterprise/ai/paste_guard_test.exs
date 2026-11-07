defmodule AshEnterprise.AI.PasteGuardTest do
  @moduledoc """
  The paste guard (`AshEnterprise.AI.SecretShape`, AGT-64): text a person wrote that is
  shaped like a secret never reaches a model. Refused at the assistant's intake before
  anything is stored, and at every guarded model call before anything is recorded or
  sent: no `AshEnterprise.AI.ModelCall` row, no transport call. The refusal points to
  the connection screen and never repeats the text.

  The secret-shaped strings are assembled at run time from synthetic pieces, so no
  string in this file is one.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.AI.{ModelCall, SecretShape}
  alias AshEnterprise.AI.Models.GuardedReqLLM
  alias AshEnterprise.Assistant.{Agent, Ask, Prompt, Thread, Turn}
  alias AshEnterprise.Canonical.Commitments.ModelExtractor
  alias AshEnterprise.Execution
  alias AshEnterprise.SystemOne.DecisionWire
  alias AshEnterprise.SystemOne.QuestionProposal.Transport, as: ProposalTransport
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.AssistantFixtures.ScriptedModel

  defmodule Transport do
    @moduledoc false
    # Stands in for ReqLLM: any call reaching it is reported to the test process.
    def generate_text(_model, _context, _opts) do
      send(:paste_guard_test, :transport_called)
      {:ok, %{usage: %{input_tokens: 1, output_tokens: 1}}}
    end

    def generate_object(_model, _context, _schema, _opts) do
      send(:paste_guard_test, :transport_called)
      {:ok, %{object: %{}, usage: %{input_tokens: 1, output_tokens: 1}}}
    end

    def stream_text(_model, _context, _opts) do
      send(:paste_guard_test, :transport_called)
      {:error, :not_used}
    end
  end

  # Secret shapes, built from parts.
  defp token, do: "gh" <> "p_" <> String.duplicate("SYNTHETIC0", 4)
  defp access_key, do: String.slice("AK" <> "IA" <> String.duplicate("SYNTHETIC0", 2), 0, 20)
  defp private_key, do: "-----BEGIN " <> "RSA PRIVATE" <> " KEY-----\nSYNTHETIC\n"
  defp jwt, do: Enum.map_join(1..3, ".", fn _ -> "eyJ" <> String.duplicate("U1lOVEg", 3) end)
  defp assignment, do: "api_key" <> " = " <> String.duplicate("synthetic", 2)
  defp url_password, do: "postgres://app:" <> "synthetic-pw" <> "@db.example.test/app"
  defp bearer, do: "Authorization: Bearer " <> String.duplicate("SyntheticTok", 3)

  defp calls, do: Ash.read!(ModelCall, authorize?: false)

  setup do
    Process.register(self(), :paste_guard_test)
    F.in_zone!()
    :ok
  end

  describe "the shapes" do
    test "each known shape is refused by its kind" do
      assert SecretShape.check("my token is #{token()}") == {:refused, :token}
      assert SecretShape.check("key #{access_key()} please") == {:refused, :access_key}
      assert SecretShape.check(private_key()) == {:refused, :private_key}
      assert SecretShape.check("jwt: #{jwt()}") == {:refused, :token}
      assert SecretShape.check(bearer()) == {:refused, :token}
      assert SecretShape.check(assignment()) == {:refused, :password}
      assert SecretShape.check("connect to #{url_password()}") == {:refused, :password}
    end

    test "references, ids and questions about secrets are not secrets" do
      for text <- [
            "SYNTHETIC: explain invocation:#{Ash.UUID.generate()}",
            "SYNTHETIC: what is our password policy?",
            "SYNTHETIC: password: %{password}",
            "SYNTHETIC: where do I put my API key?",
            "SYNTHETIC: #{String.duplicate("abcdefghij", 8)}",
            "https://example.test/path?x=1"
          ] do
        assert SecretShape.check(text) == :ok, text
      end

      assert SecretShape.check(nil) == :ok
      assert SecretShape.check(%{not: "text"}) == :ok
    end

    test "only person-written messages of a request are checked" do
      context =
        ReqLLM.Context.new([
          ReqLLM.Context.system("SYNTHETIC system #{token()}"),
          ReqLLM.Context.user("SYNTHETIC: a plain question")
        ])

      assert SecretShape.check_request(context) == :ok

      pasted = ReqLLM.Context.new([ReqLLM.Context.user("SYNTHETIC: use #{token()}")])
      assert SecretShape.check_request(pasted) == {:refused, :token}
      assert SecretShape.check_request("SYNTHETIC #{access_key()}") == {:refused, :access_key}

      assert SecretShape.check_request([%{"role" => "user", "content" => jwt()}]) ==
               {:refused, :token}
    end
  end

  describe "every guarded model call" do
    test "refuses a pasted secret with no call record and no transport call" do
      model = F.target().spec
      before = length(calls())
      context = ReqLLM.Context.new([ReqLLM.Context.user("SYNTHETIC: try #{token()}")])
      opts = [caller: "test.paste", downstream: Transport]

      assert {:error, %SecretShape.Refused{kind: :token} = refused} =
               GuardedReqLLM.generate_text(model, context, opts)

      assert {:error, %SecretShape.Refused{}} =
               GuardedReqLLM.generate_object(model, context, %{}, opts)

      assert {:error, %SecretShape.Refused{}} = GuardedReqLLM.stream_text(model, context, opts)

      refute_received :transport_called
      assert length(calls()) == before

      message = Exception.message(refused)
      assert message =~ "/app/accounts"
      refute message =~ token()
    end

    test "a request with nothing pasted goes through and is recorded" do
      before = length(calls())
      context = ReqLLM.Context.new([ReqLLM.Context.user("SYNTHETIC: a plain question")])

      assert {:ok, _} =
               GuardedReqLLM.generate_text(F.target().spec, context,
                 caller: "test.paste",
                 downstream: Transport
               )

      assert_received :transport_called
      assert length(calls()) == before + 1
    end

    test "an agent run whose input holds a secret makes no model call" do
      ctx = F.tenant!()
      F.published!(ctx)
      ScriptedModel.script!([{:text, "SYNTHETIC: must not be asked"}])
      before = length(calls())

      {:ok, run} =
        Execution.start_agent_run(
          Agent.key(),
          Prompt.input("SYNTHETIC: use #{access_key()}", []),
          %{run_key: "paste:#{Ash.UUID.generate()}", origin: :assistant},
          F.opts(ctx)
        )

      run = F.run_out!(run)

      refute_received {:model_request, _messages, _tools, _opts}
      assert length(calls()) == before
      refute run.status == :completed
    end
  end

  describe "every model call path, not only the assistant's" do
    test "commitment extraction never sends a sent message holding a secret" do
      previous = Application.get_env(:ash_enterprise, ModelExtractor)
      Application.put_env(:ash_enterprise, ModelExtractor, downstream: Transport)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_enterprise, ModelExtractor, previous),
          else: Application.delete_env(:ash_enterprise, ModelExtractor)
      end)

      before = length(calls())

      body = "SYNTHETIC: I'll send the deck Friday.\nexport KEY=#{access_key()}"

      assert {:error, %SecretShape.Refused{kind: :access_key, caller: "canonical.commitments"}} =
               ModelExtractor.extract(%{text: body, sent_at: DateTime.utc_now()}, F.target())

      refute_received :transport_called
      assert length(calls()) == before
    end

    test "a proposal prompt holding a secret never reaches the wire" do
      parent = self()

      capture = fn conn ->
        send(parent, :wire_reached)
        Plug.Conn.send_resp(conn, 500, "{}")
      end

      System.put_env("S1_GEN_BASE_URL", "http://splash.invalid:8000/v1")
      on_exit(fn -> System.delete_env("S1_GEN_BASE_URL") end)

      {:ok, spec, opts} = ProposalTransport.ReqLLM.resolve(:splash_generative)
      opts = Keyword.put(opts, :req_http_options, plug: capture, retry: false)
      before = length(calls())

      assert {:error, %SecretShape.Refused{kind: :token, caller: "system_one.proposal"}} =
               ProposalTransport.ReqLLM.generate(
                 spec,
                 opts,
                 %{"type" => "object"},
                 "SYNTHETIC policy text: the service token is #{token()}"
               )

      refute_received :wire_reached
      assert length(calls()) == before
    end

    test "a judgment whose state holds a secret is never evaluated" do
      parent = self()

      capture = fn conn ->
        send(parent, :wire_reached)
        Plug.Conn.send_resp(conn, 500, "{}")
      end

      previous = Application.get_env(:ash_judgments, :profiles)

      Application.put_env(:ash_judgments, :profiles, [
        [
          name: :paste_guard_judge,
          model: "synthetic-judge",
          base_url: {:system, "PASTE_GUARD_JUDGE_URL", "http://judge.invalid:8000"},
          api_key: {:system, "PASTE_GUARD_JUDGE_KEY", "in-zone-no-key"},
          residency: :in_cluster,
          region: :ca
        ]
      ])

      on_exit(fn -> Application.put_env(:ash_judgments, :profiles, previous) end)

      state = %{"subject" => %{"notes" => ["SYNTHETIC: see #{private_key()}"]}}

      assert {:error, %SecretShape.Refused{kind: :private_key}} =
               DecisionWire.evaluate(
                 "typesafe:synthetic-judge",
                 state,
                 %{ok: %{type: :boolean, instructions: "SYNTHETIC?"}},
                 req_http_options: [plug: capture, retry: false]
               )

      refute_received :wire_reached
    end

    test "a judgment state with nothing pasted is not refused by the guard" do
      assert SecretShape.check_values(%{"a" => ["SYNTHETIC: plain", {:b, "words"}]}) == :ok
      assert SecretShape.check_values(%{"a" => [%{"b" => jwt()}]}) == {:refused, :token}
      assert SecretShape.check_values(nil) == :ok
    end
  end

  describe "the assistant's intake" do
    setup do
      ctx = F.tenant!()
      F.published!(ctx)
      Map.put(ctx, :thread, F.thread!(ctx))
    end

    test "refuses the question before it is stored, asked or recorded", ctx do
      ScriptedModel.script!([{:text, "SYNTHETIC: must not be asked"}])
      before = length(calls())

      assert {:error, :secret_shaped, %{question: nil, answer: nil}} =
               Ask.ask(ctx.thread, "SYNTHETIC: here is my key #{access_key()}", F.opts(ctx))

      assert Ask.pasted("SYNTHETIC: #{private_key()}") == {:error, :secret_shaped}
      assert Ask.pasted("SYNTHETIC: a plain question") == :ok

      assert Turn
             |> Ash.Query.filter(thread_id == ^ctx.thread.id)
             |> Ash.read!(authorize?: false) == []

      assert Execution.list_agent_runs!(authorize?: false, tenant: ctx.tenant) == []
      refute_received {:model_request, _messages, _tools, _opts}
      assert length(calls()) == before
      assert %Thread{} = ctx.thread
    end
  end
end
