defmodule Mix.Tasks.AshEnterprise.Integration.Sync do
  @shortdoc "Dev only: runs sync steps for one linked account by hand, printing counts only"

  @moduledoc """
  Runs one (or `--steps N`) sync steps for one linked account, inline, as the
  account's owner — the same step the scheduled job runs, without Oban.

      mix ash_enterprise.integration.sync --linked-account <id> [--steps 3] [--unblock]

  Prints one line per step: a status (`complete`, `more`, `rate_limited`,
  `cancelled`, `failed`) and counts — never a payload, a name or a connection
  id. Stops early once a step completes, cancels, fails or is rate limited.

  * Dev and test only: in any other environment the task refuses.
  * Needs `NANGO_SECRET_KEY` in the environment (and `NANGO_BASE_URL` if Nango
    is not on `127.0.0.1:3003`); the edge reads them at call time.
  * Runs under the owner's grants, exactly as the job does. A shredded scope,
    a deactivated account or a missing grant cancels the step before any
    provider request.
  * `--unblock` clears a sync block first (`AshEnterprise.Integration.SyncBlock`:
    the scheduler skips an account whose last step cancelled for a revoked
    token, a deleted connection, a shredded scope or an inactive owner). A
    blocked account still runs by hand; it is only the scheduler that skips it.
  """

  use Mix.Task

  alias AshEnterprise.Integration.{Console, LinkedAccount}
  alias AshEnterprise.Mix.Helpers

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    unless Mix.env() in [:dev, :test] do
      Mix.raise("ash_enterprise.integration.sync is a dev tool; refusing in #{Mix.env()}")
    end

    {id, steps, unblock?} = parse!(argv)

    # Repo only: the step runs inline, so Oban's queues are not started and
    # cannot race it (iron law #23).
    Helpers.boot_repo()
    Helpers.load_domain_resources()

    {account, actor} = account_and_owner!(id)
    if unblock?, do: unblock!(account, actor)
    if account.sync_blocked_at && !unblock?, do: Mix.shell().info(blocked_note(account))

    Enum.reduce_while(1..steps, :ok, fn n, :ok ->
      result = Console.step(account, actor)

      Mix.shell().info(
        "step #{n}/#{steps} #{account.provider_config_key} #{Console.format(result)}"
      )

      if result.status == :more, do: {:cont, :ok}, else: {:halt, :ok}
    end)
  end

  defp parse!(argv) do
    {opts, _args, _invalid} =
      OptionParser.parse(argv,
        strict: [linked_account: :string, steps: :integer, unblock: :boolean]
      )

    id = opts[:linked_account] || Mix.raise("--linked-account <id> is required")
    steps = opts[:steps] || 1
    if steps < 1, do: Mix.raise("--steps must be at least 1")
    {id, steps, opts[:unblock] == true}
  end

  defp blocked_note(account) do
    "note: the scheduler skips this account (sync blocked: #{account.sync_blocked_reason}); " <>
      "pass --unblock to clear it"
  end

  defp unblock!(account, actor) do
    case LinkedAccount.unblock_sync(account, actor: actor, tenant: account.organization_id) do
      {:ok, _account} -> Mix.shell().info("unblocked #{account.id}")
      {:error, _error} -> Mix.raise("could not unblock #{account.id} as its owner")
    end
  end

  defp account_and_owner!(id) do
    with {:ok, account} <- Console.linked_account(id),
         {:ok, actor} <- Console.actor_for_owner(account) do
      {account, actor}
    else
      {:error, :no_such_linked_account} -> Mix.raise("no linked account #{id}")
      {:error, _} -> Mix.raise("linked account #{id} has no owner")
    end
  end
end
