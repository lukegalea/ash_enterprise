# Compiled only when ash_agent_tools is loaded (dev and test), like the
# standing job it drives; see AshEnterprise.Standards. The crontab entry in
# config/config.exs is therefore absent from a production build.
if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Standing) do
  defmodule AshEnterprise.Standards.StandingWorker do
    @moduledoc """
    The standards standing check, run inside the app on a schedule: a
    machinery-only job under the `oban` system actor (ADR 0059) that drives
    `AshEnterprise.Standards.Standing.run/2` over a checkout of `main`.

    It replaces a host systemd timer that drove the same function over
    `:erpc` and kept the last judged HEAD in a state file. It reasons about
    nothing: it is the judge calls and the banding step, so an agent run
    would be the wrong tool.

    ## Configuration, off by default

        config :ash_enterprise, AshEnterprise.Standards.StandingWorker,
          enabled: false,
          root: "/path/to/checkout",
          tenant: "dogfood",
          limit: nil,
          cron: "17 * * * *"

      * `:enabled`: the job does nothing until this is `true`.
      * `:root`: the checkout to judge. Required once enabled.
      * `:tenant`: the `unique_name` of the organization whose ledger and
        band tables the run uses.
      * `:limit`: at most this many pending units per question. A run
        narrowed by a limit (or by `:questions`) never marks the HEAD.
      * `:cron`: the schedule; read when `config/config.exs` is evaluated.
      * `:force`: judge even when the HEAD has not moved.
      * `:instrument`: a map, or a zero-arity function returning
        `{:ok, map}`, replacing the default instrument lookup.
      * `:standing_opts`: further options for `Standing.run/2` (a test
        transport, a resolver, `:paths`).

    ## The last judged HEAD

    Held in `AshEnterprise.SystemOne.StandingHead`, per tenant and
    repository. A tick whose checkout is still at that sha does nothing.
    The sha is marked only after a full run (no limit, no question filter)
    in which no unit met a judge error; anything else leaves it behind so
    the next tick looks again. Units already admitted read as current, so a
    repeat run judges only what is still pending.

    ## The instrument identity

    Each judgment records the model version, the model digest and the
    runtime version it was answered by. The worker reads them once per run
    from the `:winnow_gpu` profile, the digest the runtime reports for that
    model and the runtime's `/api/version`, the way the calibration pass
    does. A run whose instrument cannot be identified judges nothing and
    fails, instead of recording answers with no provenance.
    """

    use Oban.Worker,
      queue: :system_one,
      max_attempts: 1,
      unique: [period: :infinity, states: :incomplete]

    require Logger

    alias AshEnterprise.Accounts.Organization
    alias AshEnterprise.Platform.SystemActor
    alias AshEnterprise.Standards.Standing
    alias AshEnterprise.SystemOne.StandingHead

    @repository "ash_enterprise"
    @profile :winnow_gpu

    @impl Oban.Worker
    def perform(%Oban.Job{}) do
      config = config()

      if config[:enabled] == true do
        run(config)
      else
        {:ok, :disabled}
      end
    end

    @doc "The worker's configuration (see the moduledoc)."
    @spec config() :: keyword()
    def config, do: Application.get_env(:ash_enterprise, __MODULE__, [])

    @doc """
    One run with `config` (the keys of the moduledoc). Returns
    `{:ok, :unchanged}` when the HEAD was already judged, `{:ok, summary}`
    (`%{head:, judged:, errors:, marked?:}`), or `{:error, reason}` with
    nothing judged and the HEAD left unmarked.
    """
    @spec run(keyword()) :: {:ok, :unchanged | map()} | {:error, term()}
    def run(config) do
      standing_opts = Keyword.get(config, :standing_opts, [])
      repository = Keyword.get(standing_opts, :repository, @repository)

      with {:ok, root} <- fetch_root(config),
           {:ok, head} <- checkout_head(root),
           {:ok, tenant} <- tenant_id(config),
           last = last_head(tenant, repository),
           false <- unchanged?(last, head, config),
           {:ok, instrument} <- instrument(config) do
        judge(root, head, tenant, repository, instrument, config, standing_opts)
      else
        true -> {:ok, :unchanged}
        {:error, _} = error -> error
      end
    end

    defp judge(root, head, tenant, repository, instrument, config, standing_opts) do
      narrowing = narrowing(config)

      results =
        Standing.run(
          root,
          [tenant: tenant, instrument: instrument, actor: SystemActor.oban()] ++
            narrowing ++ standing_opts
        )

      errors = Enum.count(results, &match?({:error, _}, &1.result))
      marked? = narrowing == [] and errors == 0

      if marked? do
        StandingHead.mark!(
          %{subject_tenant_id: tenant, repository: repository, head: head},
          actor: SystemActor.oban()
        )
      end

      Logger.info(
        "standards standing: judged #{length(results)} units at #{String.slice(head, 0, 7)}, " <>
          "#{errors} errors, head #{if marked?, do: "marked", else: "left unmarked"}"
      )

      {:ok, %{head: head, judged: length(results), errors: errors, marked?: marked?}}
    end

    defp narrowing(config) do
      [limit: config[:limit], questions: config[:questions]]
      |> Enum.reject(fn {_, value} -> value in [nil, []] end)
    end

    defp unchanged?(nil, _head, _config), do: false
    defp unchanged?(%{head: last}, head, config), do: last == head and config[:force] != true

    defp last_head(tenant, repository),
      do: StandingHead.for_scope!(tenant, repository, actor: SystemActor.oban())

    defp fetch_root(config) do
      case config[:root] do
        root when is_binary(root) and root != "" -> {:ok, root}
        _ -> {:error, :no_root}
      end
    end

    defp checkout_head(root) do
      case System.cmd("git", ["-C", root, "rev-parse", "HEAD"], stderr_to_stdout: true) do
        {out, 0} -> {:ok, String.trim(out)}
        {out, _} -> {:error, {:git, String.trim(out)}}
      end
    end

    defp tenant_id(config) do
      case config[:tenant] do
        name when is_binary(name) ->
          case Organization.by_unique_name(name, actor: SystemActor.oban()) do
            {:ok, %{id: id}} -> {:ok, id}
            _ -> {:error, {:unknown_tenant, name}}
          end

        _ ->
          {:error, :no_tenant}
      end
    end

    defp instrument(config) do
      case Keyword.get(config, :instrument, &default_instrument/0) do
        %{} = instrument -> {:ok, instrument}
        fun when is_function(fun, 0) -> fun.()
      end
    end

    @doc """
    The `:winnow_gpu` instrument's identity: the profile's model, the digest
    the runtime reports for it and the runtime's version.
    """
    @spec default_instrument() :: {:ok, map()} | {:error, term()}
    def default_instrument do
      with {:ok, profile} <- AshJudgments.Profile.fetch(@profile),
           {:ok, digest} <- AshJudgments.Profile.Digest.fetch(profile),
           {:ok, transport} <- AshJudgments.Profile.req_llm_opts(profile),
           {:ok, version} <- runtime_version(Keyword.fetch!(transport, :base_url)) do
        {:ok, %{model_version: profile.model, model_digest: digest, runtime_version: version}}
      end
    end

    defp runtime_version(base_url) do
      case Req.get(base_url <> "/api/version", retry: false) do
        {:ok, %{status: 200, body: %{"version" => version}}} -> {:ok, "ollaya-" <> version}
        other -> {:error, {:runtime_version_unavailable, other}}
      end
    end
  end
end
