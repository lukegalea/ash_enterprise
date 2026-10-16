defmodule AshEnterpriseWeb.A2ui.AccountsUITest do
  @moduledoc """
  Accounts & syncs (`AccountsUI`, `/app/accounts`): bulk Sync now driven
  through ash_a2ui's own handler, as the person who clicks it. Each selected
  account syncs through its own vertical, as the actor; a paused account is
  skipped, not forced; ids the reader cannot read are refused, and a person
  who may not sync gets nothing enqueued.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, linked_account!: 3]

  alias AshEnterprise.Integration.{Calendar, Gmail, LinkedAccount}
  alias AshEnterpriseWeb.A2ui.AccountsUI

  setup do
    %{admin: tenant!()}
  end

  defp bulk(person, accounts) do
    AshA2ui.ActionHandler.handle(
      AccountsUI,
      %{
        "name" => "bulk_invoke",
        "context" => %{
          "action" => "sync_now",
          "component" => "table",
          "records" => Enum.map(accounts, &%{"id" => &1.id, "_selected" => true})
        }
      },
      actor: person.actor,
      tenant: person.tenant
    )
  end

  # The run's tally, as the handler writes it to `/bulk/table/result`.
  defp result(messages) do
    Enum.find_value(messages, fn
      %{"updateDataModel" => %{"path" => "/bulk/table/result", "value" => value}} -> value
      _other -> nil
    end)
  end

  defp enqueued_for(worker),
    do: Enum.map(all_enqueued(worker: worker), & &1.args["linked_account_id"])

  defp pause!(account, person) do
    account
    |> Ash.Changeset.for_update(:deactivate, %{}, actor: person.actor, tenant: person.tenant)
    |> Ash.update!()
  end

  test "Sync now runs over a selection, each account through its own vertical, skipping a paused one",
       %{admin: admin} do
    calendar = linked_account!(admin, "google-calendar", "work")
    mail = linked_account!(admin, "google-mail", "work")
    paused = admin |> linked_account!("google-calendar", "old") |> pause!(admin)

    assert {:ok, messages} = bulk(admin, [calendar, mail, paused])
    assert %{"ok" => 2, "skipped" => 1, "refused" => 0, "failed" => 0} = result(messages)

    assert enqueued_for(Calendar.SyncWorker) == [calendar.id]
    assert enqueued_for(Gmail.SyncWorker) == [mail.id]
  end

  test "ids the reader cannot read are refused, never synced", %{admin: admin} do
    account = linked_account!(admin, "google-calendar", "work")
    stranger = member!(admin, "No grants", [])

    assert {:error, _messages} = bulk(stranger, [account])
    assert enqueued_for(Calendar.SyncWorker) == []
  end

  test "a person who may read accounts but not sync them gets nothing enqueued", %{admin: admin} do
    account = linked_account!(admin, "google-calendar", "work")
    reader = member!(admin, "Accounts reader", [{LinkedAccount, :read, :global}])

    assert {:error, messages} = bulk(reader, [account])
    assert %{"ok" => 0} = result(messages)
    assert enqueued_for(Calendar.SyncWorker) == []
  end
end
