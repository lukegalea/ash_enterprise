defmodule AshEnterprise.Test.AssistantFixtures do
  @moduledoc """
  SYNTHETIC fixtures for the assistant (`AshEnterprise.Assistant`): an
  in-zone profile pointed at no host, a scripted model standing in for it,
  and a tenant with a second person in it. Nothing here reaches a network or
  reads real data; every name and address is on `example.test`.
  """

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Canonical.Projections.ZoneAdmission
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  @zone "assistant-test-zone"
  @model "synthetic/in-zone-assistant"
  @base_url "http://in-zone.invalid:8000/v1"

  def zone, do: @zone

  @doc """
  Configures the in-zone profile (`@model` at an unroutable host, in
  `@zone`), names `@zone` as the canonical store's zone, and routes the
  runner's model calls to `ScriptedModel`. Restored on exit.
  """
  def in_zone!(opts \\ []) do
    keys = [:ai, ZoneAdmission, AshEnterprise.Assistant.Runner]
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

    Application.put_env(:ash_enterprise, AshEnterprise.Assistant.Runner,
      req_llm_opts: [downstream: __MODULE__.ScriptedModel]
    )

    :ok
  end

  defp restore({key, nil}), do: Application.delete_env(:ash_enterprise, key)
  defp restore({key, value}), do: Application.put_env(:ash_enterprise, key, value)

  @doc "The run's model target as the runner resolves it."
  def target, do: AshEnterprise.AI.Models.resolve(AshEnterprise.AI.Models.default_spec())

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

  @doc "Runs one assistant tool as `ctx`'s person, with `target` (default: the in-zone one)."
  def tool!(ctx, name, input, target \\ :in_zone) do
    context =
      case target do
        :in_zone -> %{AshEnterprise.Assistant.ZoneGate.key() => target()}
        nil -> %{}
        other -> %{AshEnterprise.Assistant.ZoneGate.key() => other}
      end

    AshEnterprise.Assistant.Lookup
    |> Ash.ActionInput.for_action(name, input,
      actor: ctx.actor,
      tenant: ctx.tenant,
      context: context,
      authorize?: true
    )
    |> Ash.run_action!()
  end

  defmodule ScriptedModel do
    @moduledoc """
    Stands in for ReqLLM behind `AshEnterprise.AI.Models.GuardedReqLLM`
    (`downstream:`). Each `stream_text/3` call takes the next step of the
    script and reports the request to the scripting process:

      * `{:tools, [{name, arguments}]}` — the model calls those tools;
      * `{:text, text}` — the model answers;
      * `{:error, reason}` — the call fails to open;
      * `{:raise, exception}` — the stream opens, then fails while read;
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
        |> Enum.map(fn {{name, arguments}, i} ->
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
