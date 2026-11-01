defmodule AshEnterprise.Test.AssistantFixtures do
  @moduledoc """
  SYNTHETIC fixtures for the assistant (`AshEnterprise.Assistant`): an
  in-zone profile pointed at no host, a scripted model standing in for it,
  a tenant with a second person in it, the assistant agent published there,
  and a driver that steps an answer's run the way its jobs do. Nothing here
  reaches a network or reads real data; every name and address is on
  `example.test`.
  """

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Assistant.{Ask, Thread}
  alias AshEnterprise.Canonical.Projections.ZoneAdmission
  alias AshEnterprise.Execution.AgentRuntime
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  @zone "assistant-test-zone"
  @model "synthetic/in-zone-assistant"
  @base_url "http://in-zone.invalid:8000/v1"

  def zone, do: @zone

  @doc """
  Configures the in-zone profile (`@model` at an unroutable host, in
  `@zone`), names `@zone` as the canonical store's zone, and routes every
  agent run's model calls to `ScriptedModel`. Restored on exit.
  """
  def in_zone!(opts \\ []) do
    keys = [:ai, ZoneAdmission, AgentRuntime]
    previous = Map.new(keys, &{&1, Application.get_env(:ash_enterprise, &1)})

    ExUnit.Callbacks.on_exit(fn -> Enum.each(previous, &restore/1) end)

    profile_zone = Keyword.get(opts, :profile_zone, @zone)

    Application.put_env(
      :ash_enterprise,
      :ai,
      [in_zone_generative: [model: @model, base_url: @base_url, zone: profile_zone]] ++
        Keyword.get(opts, :ai, [])
    )

    Application.put_env(:ash_enterprise, ZoneAdmission, zone: @zone)

    Application.put_env(:ash_enterprise, AgentRuntime,
      req_llm_opts: [downstream: __MODULE__.ScriptedModel]
    )

    :ok
  end

  defp restore({key, nil}), do: Application.delete_env(:ash_enterprise, key)
  defp restore({key, value}), do: Application.put_env(:ash_enterprise, key, value)

  @doc "The model target every run step calls."
  def target, do: AgentRuntime.target()

  @doc "A seeded tenant: `%{actor:, user:, tenant:, role:, business_unit:}`."
  def tenant! do
    n = System.unique_integer([:positive])

    seeded =
      Seeder.seed_tenant(
        name: "Assistant #{n}",
        unique_name: "assistant-#{n}",
        email: "alice-#{n}@example.test"
      )

    %{
      actor: actor(seeded.user, seeded.organization.id),
      user: seeded.user,
      tenant: seeded.organization.id,
      organization: seeded.organization,
      role: seeded.role,
      business_unit: seeded.business_unit
    }
  end

  @doc """
  Another person in `ctx`'s tenant and business unit. `admin?: true` gives
  them the tenant's Administrator role; otherwise they hold no role at all.
  """
  def colleague!(ctx, opts \\ []) do
    n = System.unique_integer([:positive])

    user =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "bob-#{n}@example.test",
          password: "password1234",
          password_confirmation: "password1234"
        },
        authorize?: false
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(
        :assign_to_business_unit,
        %{owning_business_unit_id: ctx.business_unit.id},
        authorize?: false
      )
      |> Ash.update!()

    if Keyword.get(opts, :admin?, false) do
      Security.UserRole
      |> Ash.Changeset.for_create(
        :assign,
        %{user_id: user.id, role_id: ctx.role.id, scoping_business_unit_id: ctx.business_unit.id},
        tenant: ctx.tenant,
        authorize?: false
      )
      |> Ash.create!()
    end

    user = Ash.reload!(user, authorize?: false)
    %{actor: actor(user, ctx.tenant), user: user, tenant: ctx.tenant}
  end

  def actor(user, org_id), do: ActorContext.attach(user, ActorContext.build(user, tenant: org_id))

  @doc """
  Runs one assistant tool as `ctx`'s person, as a run's step hands it its context
  (`run?: false`: as a caller with no run), and returns its rows as the model reads
  them: string keys, empty fields left out. A refusal raises; `refusal/4` returns it.
  """
  def tool!(ctx, name, input, opts \\ []) do
    {:ok, rows} = tool(ctx, name, input, opts)
    rows
  end

  @doc "The refusal one assistant tool answers `ctx`'s person with: its message, as the model reads it."
  def refusal(ctx, name, input, opts \\ []) do
    {:error, error} = tool(ctx, name, input, opts)

    error
    |> Ash.Error.to_error_class()
    |> Map.fetch!(:errors)
    |> Enum.map_join("; ", & &1.message)
  end

  defp tool(ctx, name, input, opts) do
    %{resource: resource, action: action} =
      Enum.find(AshAi.Info.tools(AshEnterprise.Assistant), &(&1.name == name))

    context =
      if Keyword.get(opts, :run?, true),
        do: %{ash_agent: %{run_id: Ash.UUID.generate()}},
        else: %{}

    resource
    |> Ash.Query.for_read(action, input,
      actor: ctx.actor,
      tenant: ctx.tenant,
      context: context,
      authorize?: true
    )
    |> Ash.read()
    |> case do
      {:ok, rows} -> {:ok, Enum.map(rows, &fields/1)}
      {:error, error} -> {:error, error}
    end
  end

  defp fields(row) do
    row.__struct__
    |> Ash.Resource.Info.public_attributes()
    |> Enum.flat_map(fn %{name: name} ->
      case Map.get(row, name) do
        value when value in [nil, "", []] -> []
        value -> [{Atom.to_string(name), value}]
      end
    end)
    |> Map.new()
  end

  @doc """
  Publishes the assistant agent in `ctx`'s tenant under four eyes (its administrator
  asks, a second administrator approves) and gives `members` (default: `ctx` itself)
  its start grant. Returns the published version.
  """
  def published!(ctx, members \\ nil) do
    approver = colleague!(ctx, admin?: true)

    version =
      AshEnterprise.Test.Execution.Runs.publish!(ctx, approver, AshEnterprise.Assistant.Agent)

    for member <- members || [ctx],
        do: AshEnterprise.Test.Execution.Authority.start_grant!(ctx, member, "assistant")

    version
  end

  @doc """
  Asks `question` in `thread` as `ctx`'s person and steps its run the way its jobs do,
  until it has ended or waits on a limit, then records the answer. Returns what
  `AshEnterprise.Assistant.Ask.settle/3` returns, or the refusal `Ask.ask/3` returned.
  """
  def ask!(ctx, %Thread{} = thread, question) do
    opts = opts(ctx)

    case Ask.ask(thread, question, opts) do
      {:ok, %{run: run}} -> answer!(ctx, thread, run)
      {:error, reason, %{answer: answer}} -> {:error, reason, answer}
    end
  end

  @doc "Steps `run` until it ends (at most `steps` times), then records its answer."
  def answer!(ctx, thread, run, steps \\ 12) do
    run_out!(run, steps)
    Ask.settle(thread, run.id, opts(ctx))
  end

  @doc """
  Does `run`'s jobs here: steps it while it is queued or running, at most `steps`
  times. Returns the run as it then stands.
  """
  def run_out!(run, steps \\ 12) do
    Enum.reduce_while(1..steps, run, fn _n, run ->
      case AshEnterprise.Test.Execution.Runs.run(run) do
        %{status: status} = run when status in [:queued, :running] ->
          _ = AshEnterprise.Test.Execution.Runs.step!(run)
          {:cont, run}

        run ->
          {:halt, run}
      end
    end)
  end

  @doc "A new thread of `ctx`'s person."
  def thread!(ctx, title \\ "SYNTHETIC: a question"),
    do: Thread.start!(title, opts(ctx))

  @doc "Options to act as `ctx`'s person."
  def opts(ctx), do: [actor: ctx.actor, tenant: ctx.tenant, authorize?: true]

  defmodule ScriptedModel do
    @moduledoc """
    Stands in for ReqLLM behind `AshEnterprise.AI.Models.GuardedReqLLM`
    (`downstream:`). Each `stream_text/3` call takes the next step of the
    script and reports the request to the scripting process:

      * `{:tools, [{name, arguments}]}` — the model calls those tools
        (`{id, name, arguments}` names the call's id);
      * `{:text, text}` — the model answers;
      * `{:error, reason}` — the call fails to open;
      * `{:raise, exception}` — the stream opens, then fails while read;
      * `{:exit, reason}` — the stream opens, then the process reading it exits
        with `reason`, as a worker that dies during its model call;
      * `{:pause, text}` — one chunk of `text`, then waits for
        `:scripted_continue` before sending the rest (a slow model).

    The script lives in a named Agent so a run in another process (the
    LiveView's) reads the same one. Synthetic text only.
    """

    use Agent

    def script!(steps) do
      owner = self()

      case Process.whereis(__MODULE__) do
        nil ->
          {:ok, _} = Agent.start(fn -> %{steps: steps, owner: owner} end, name: __MODULE__)

        _pid ->
          Agent.update(__MODULE__, fn _ -> %{steps: steps, owner: owner} end)
      end

      ExUnit.Callbacks.on_exit(fn ->
        if pid = Process.whereis(__MODULE__), do: Agent.stop(pid)
      end)

      :ok
    end

    def remaining, do: Agent.get(__MODULE__, & &1.steps)

    def stream_text(model, context, opts) do
      {step, owner} =
        Agent.get_and_update(__MODULE__, fn
          %{steps: [step | rest]} = state -> {{step, state.owner}, %{state | steps: rest}}
          %{steps: []} = state -> {{{:text, "SYNTHETIC: the script ran out"}, state.owner}, state}
        end)

      send(owner, {:model_request, messages(context), tool_names(opts), opts})
      respond(step, model, context)
    end

    defp respond({:error, reason}, _model, _context), do: {:error, reason}

    defp respond({:tools, calls}, model, context) do
      chunks =
        calls
        |> Enum.with_index()
        |> Enum.map(fn
          {{id, name, arguments}, i} ->
            ReqLLM.StreamChunk.tool_call(name, arguments, %{id: id, index: i})

          {{name, arguments}, i} ->
            ReqLLM.StreamChunk.tool_call(name, arguments, %{
              id: "call_#{System.unique_integer([:positive])}",
              index: i
            })
        end)

      response(chunks, :tool_calls, model, context)
    end

    defp respond({:text, text}, model, context),
      do: response([ReqLLM.StreamChunk.text(text)], :stop, model, context)

    defp respond({:raise, exception}, model, context) do
      {:ok, response} = response([], :stop, model, context)
      {:ok, %{response | stream: Stream.map([1], fn _ -> raise exception end)}}
    end

    defp respond({:exit, reason}, model, context) do
      {:ok, response} = response([], :stop, model, context)
      {:ok, %{response | stream: Stream.map([1], fn _ -> exit(reason) end)}}
    end

    defp respond({:pause, text}, model, context) do
      stream =
        Stream.resource(
          fn -> :first end,
          fn
            :first ->
              {[ReqLLM.StreamChunk.text(text)], :wait}

            :wait ->
              receive do
                :scripted_continue -> {[ReqLLM.StreamChunk.text(" SYNTHETIC-REST")], :done}
              after
                5_000 -> {:halt, :done}
              end

            :done ->
              {:halt, :done}
          end,
          fn _ -> :ok end
        )

      {:ok, response} = response([], :stop, model, context)
      {:ok, %{response | stream: stream}}
    end

    defp response(chunks, finish, model, context) do
      {:ok, handle} =
        ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
          %{usage: %{input_tokens: 40, output_tokens: 8}, finish_reason: finish}
        end)

      {:ok,
       %ReqLLM.StreamResponse{
         stream: chunks,
         metadata_handle: handle,
         cancel: fn -> :ok end,
         model: model,
         context: context
       }}
    end

    defp messages(%ReqLLM.Context{messages: messages}), do: messages
    defp messages(messages) when is_list(messages), do: messages
    defp messages(_), do: []

    defp tool_names(opts), do: opts |> Keyword.get(:tools, []) |> Enum.map(& &1.name)
  end
end
