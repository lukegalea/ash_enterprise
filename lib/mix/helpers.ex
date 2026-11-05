# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshEnterprise.Mix.Helpers do
  @moduledoc """
  Shared boot for this application's mix tasks.

  Iron law #23 — mix tasks start only what they need. Most of these tasks used
  to require `app.start`, which boots the whole supervision tree: Oban (so
  queues consume jobs *while the task runs* — `audit.verify` was the worst
  offender), the `AshEvents` projector supervisor, the legacy `pg_notify`
  listener, PubSub and the Absinthe batcher. Side effects and boot time that a
  data-level task has no business paying for. See
  `docs/reviews/iron-law-audit.md`, fix item 3.

  What a Repo-backed Ash task actually needs, and what this module starts:

    * `app.config` — the task's `@requirements`; config loaded, project compiled
    * the configured Logger level applied (`apply_logger_level/0`)
    * the `:ecto_sql` and `:ash` applications
    * `AshEnterprise.Repo` running

  Not the mailer or the endpoint. A task that creates users does it through
  `AshEnterprise.Platform.Seeder.provision_user!/2`, which creates them already
  confirmed and sends nothing. `:register_with_password` would send a
  confirmation email whose link is built against the endpoint, and fail
  without it.

  Idempotent: safe to call again from a task invoked by another task (e.g.
  `ash_enterprise.seed` runs `ash_enterprise.legacy.project`), and a no-op
  after a full `app.start` (`ash_enterprise.bpmn.setup` still boots the whole
  tree, because draining Oban is the point of it).
  """

  @spec boot_repo() :: :ok
  def boot_repo do
    apply_logger_level()
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:ash)

    case AshEnterprise.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Starts Oban for inserting jobs only, after `boot_repo/0`: no queues, no
  plugins, no leadership, so nothing runs while the task does. For a task whose
  action enqueues work for the application's own nodes to run (an approval's
  expiry timer, a trigger's job). A no-op when Oban is already running.
  """
  @spec boot_oban_inserts() :: :ok
  def boot_oban_inserts do
    config =
      :ash_enterprise
      |> Application.fetch_env!(Oban)
      |> Keyword.merge(queues: false, plugins: false, peer: false)

    case Oban.start_link(config) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Applies the configured `:logger` level to the Logger that is already
  running.

  `config/runtime.exs` sets the level from `LOG_LEVEL`, and `app.config`
  loads it into the application environment, but Logger started with the VM
  and reads its level only at start. `app.start` restarts Logger, so the
  application honours it; an `app.config` task does not, and without this it
  logs at dev's `:debug`: every Ecto query with its parameters, which on an
  instance holding real data are names and addresses. A no-op when no level
  is configured.
  """
  @spec apply_logger_level() :: :ok
  def apply_logger_level do
    case Application.get_env(:logger, :level) do
      nil -> :ok
      level -> Logger.configure(level: level)
    end
  end

  @doc """
  Stops the Repo `boot_repo/0` started, so the task can hand over to one that
  requires `app.start`.

  The application supervises its own Repo, so `app.start` after `boot_repo/0`
  fails with `failed to start child: AshEnterprise.Repo ... already started`.
  `ash_enterprise.seed` runs into this when it hands over to
  `ash_enterprise.legacy.project`, which needs the whole tree (see its
  comment on why). A no-op when the application is already running, because
  the Repo is then the application's and not this module's to stop.
  """
  @spec release_repo() :: :ok
  def release_repo do
    started? = List.keymember?(Application.started_applications(), :ash_enterprise, 0)

    if not started? and Process.whereis(AshEnterprise.Repo) do
      AshEnterprise.Repo.stop()
    end

    :ok
  end

  @doc """
  Loads the configured domains and every resource in them into memory.

  Under `app.start` the domain boot did this implicitly. Two things a
  minimal-boot task needs it for:

    * `function_exported?/2`-style introspection (ash_agent_tools'
      `describe_action/2`) does not load modules it checks.
    * Stored data round-trips through the `:atom` type: an `audit_events.action`
      value like `create_default_for_business_unit` only deserializes if that
      atom exists, and it comes into being when the resource that defines the
      action is loaded.

  The pattern is the one `Ash.Mix.Tasks.Helpers` uses for the `ash.*` codegen
  tasks: compile the domain, then compile each resource it declares.
  """
  @spec load_domain_resources() :: :ok
  def load_domain_resources do
    :ash_enterprise
    |> Application.get_env(:ash_domains, [])
    |> Enum.each(fn domain ->
      with {:module, domain} <- Code.ensure_compiled(domain) do
        domain
        |> Ash.Domain.Info.resources()
        |> Enum.each(&Code.ensure_compiled/1)
      end
    end)
  end
end
