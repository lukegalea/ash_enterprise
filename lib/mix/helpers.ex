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
    * the `:ecto_sql` and `:ash` applications
    * `AshEnterprise.Repo` running
    * the `:swoosh` application — dev and test mailers deliver into an in-BEAM
      mailbox process (`Swoosh.Adapters.Local` / `Swoosh.Adapters.Test`), and
      any task that registers a user fires the confirmation sender

  Idempotent: safe to call again from a task invoked by another task (e.g.
  `ash_enterprise.seed` runs `ash_enterprise.legacy.project`), and a no-op
  after a full `app.start` (`ash_enterprise.bpmn.setup` still boots the whole
  tree, because draining Oban is the point of it).
  """

  @spec boot_repo() :: :ok
  def boot_repo do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:ash)
    {:ok, _} = Application.ensure_all_started(:swoosh)

    case AshEnterprise.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
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
