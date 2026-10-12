defmodule Mix.Tasks.AshEnterprise.Integration.Project do
  @shortdoc "Projects everything a linked account has landed, printing counts only"

  @moduledoc """
  The operator's catch-up: projects every record one linked account has
  landed into the canonical model, as the account's owner — Gmail and Slack
  through the configured zone gate, the same projection each sync step runs on
  what it just landed (`AshEnterprise.Canonical.Projections.Pending`), over
  everything instead of what is new; Google Calendar by replaying its landed
  events. Every pass re-derives the joins (`EventAttendee`,
  `ConversationParticipant`), so this is also their backfill.

      mix ash_enterprise.integration.project --linked-account <id>

  Run it once for records landed before the sync projected them, and after
  tagging an account (`mix ash_enterprise.integration.tag`): records refused
  while it was untagged are not retried by the step. Projection is an upsert
  on the source identity, so running it again converges on the same rows.

  Prints one line: a status and counts (`pending` records read, `projected`
  messages, `people`, `denied` with `denied_by` reason counts, `shredded`,
  `failed`) — never a payload, a name or a connection id. No provider is
  called.
  """

  use Mix.Task

  alias AshEnterprise.Integration.Console
  alias AshEnterprise.Mix.Helpers

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: [linked_account: :string])
    id = opts[:linked_account] || Mix.raise("--linked-account <id> is required")

    # Repo only: no Oban, no endpoint (iron law #23).
    Helpers.boot_repo()
    Helpers.load_domain_resources()

    {account, actor} = account_and_owner!(id)
    result = Console.project(account, actor)
    Mix.shell().info("project #{account.provider_config_key} #{Console.format(result)}")
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
