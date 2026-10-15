defmodule AshEnterprise.Platform.PrivilegeSync do
  @moduledoc """
  Keeps the privilege catalogue and every tenant's Administrator grants in
  step with the resources this build defines — at every boot.

  A resource added after a tenant was provisioned has privileges nobody holds,
  so the Administrator role silently stops reaching it; the symptom is a
  forbidden write (or an empty surface) on a resource an administrator can see,
  which reads as a bug in the resource rather than a stale grant. Running
  `Seeder.seed_privileges/0` and `Seeder.regrant_administrator_privileges/1`
  for each tenant on boot closes that gap without anyone remembering a deploy
  step.

  Both are idempotent and diff-only: an up-to-date deployment pays a handful
  of reads. Only the Administrator role is widened, only with globally
  grantable, non-operator privileges — the same rule `regrant_administrator_privileges/1`
  documents; every other role stays the tenant's to manage.

  Runs once, off the boot path, as a supervised `Task` (a failure is logged,
  never fatal: the application serves exactly as it would have without it).
  Off in `:test` (`config :ash_enterprise, privilege_sync?: false`), where each
  test seeds what it needs inside its own sandbox.
  """

  require Ash.Query
  require Logger

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Platform.{Seeder, SystemActor}

  @doc "The child spec: a `:temporary` `Task` running `run/0` once."
  def child_spec(_arg), do: Supervisor.child_spec({Task, &run/0}, id: __MODULE__)

  @doc "Syncs the catalogue, then each tenant's Administrator grants. Returns the counts."
  @spec run() :: %{privileges: non_neg_integer(), grants: non_neg_integer()} | :error
  def run do
    privileges = Seeder.seed_privileges()

    grants =
      Enum.reduce(tenants(), 0, &(&2 + Seeder.regrant_administrator_privileges(&1.id)))

    if privileges + grants > 0 do
      Logger.info("Privilege sync: #{privileges} privileges written, #{grants} grants added")
    end

    %{privileges: privileges, grants: grants}
  rescue
    error ->
      Logger.warning("Privilege sync skipped: #{Exception.message(error)}")
      :error
  end

  # Every real tenant; the platform organization holds baselines and has no
  # roles, so there is nothing to regrant there.
  defp tenants do
    platform = Seeder.platform_unique_name()

    Organization
    |> Ash.Query.filter(unique_name != ^platform or is_nil(unique_name))
    |> Ash.read!(actor: SystemActor.seed())
  end
end
