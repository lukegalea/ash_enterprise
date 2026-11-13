defmodule AshEnterprise.Accounts.Offboarding.Changes.RecordFromDeactivation do
  @moduledoc """
  The `record` create of `AshEnterprise.Accounts.Offboarding`: everything the row says comes
  from the `user.deactivated` occurrence it names, never from the caller.

  The caller gives only `occurrence_id`. The occurrence is read as the caller, in the
  changeset's tenant, so another organization's is not found and one the caller may not read
  is refused. It must be a deactivation (`AshEnterprise.Automation.Occurrences`), which only
  the platform writes (`Occurrence.record` is machinery-only). The leaver is the person it
  names, their state is looked up now, and their holdings are read here
  (`AshEnterprise.Accounts.Offboarding.Holdings`).

  This is what bounds the `revoke` update, which revokes the leaver's credentials without a
  second authorization: the person it acts on is one a platform-written deactivation in this
  organization named, and nobody can record a row naming anyone else, or holdings they made
  up.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Accounts.Offboarding.Actions.Open
  alias AshEnterprise.Accounts.Offboarding.Holdings
  alias AshEnterprise.Automation.{Occurrence, Occurrences}

  @impl true
  def change(changeset, _opts, context) do
    case Ash.Changeset.get_attribute(changeset, :occurrence_id) do
      nil ->
        changeset

      occurrence_id ->
        case deactivation(occurrence_id, changeset.tenant, context) do
          {:ok, leaver_id} -> record(changeset, leaver_id)
          :not_a_deactivation -> refuse(changeset)
          {:error, error} -> Ash.Changeset.add_error(changeset, error)
        end
    end
  end

  defp deactivation(occurrence_id, tenant, context) do
    opts =
      context
      |> Ash.Context.to_opts()
      |> Keyword.merge(tenant: tenant, not_found_error?: false)

    deactivated = Occurrences.deactivated()

    case Ash.get(Occurrence, occurrence_id, opts) do
      {:ok, %Occurrence{type: ^deactivated, subject: subject}} when is_binary(subject) ->
        {:ok, subject}

      {:ok, _other_or_none} ->
        :not_a_deactivation

      {:error, error} ->
        {:error, error}
    end
  end

  defp record(changeset, leaver_id) do
    state = Open.leaver_state(leaver_id)
    holdings = if state == :inactive, do: Holdings.of(leaver_id, changeset.tenant), else: %{}

    Ash.Changeset.force_change_attributes(changeset, %{
      leaver_id: leaver_id,
      leaver_state: state,
      holdings: holdings
    })
  end

  defp refuse(changeset) do
    Ash.Changeset.add_error(changeset,
      field: :occurrence_id,
      message: "is not a deactivation recorded in this organization"
    )
  end
end
