defmodule AshEnterprise.Canonical.Projections.Golden do
  @moduledoc """
  The person a projector links, after MDM has had its say (PROD-9).

  The projectors upsert people on the email address. Once a steward has
  confirmed that two addresses are one human, the merge keeps the absorbed
  row — with its address, so the next projection still finds it — and points
  it at its golden record (`merged`, `master_id`; ADR 0017/0054). A projector
  that linked the absorbed row would undo the merge one message at a time, so
  every link a projector writes (`Message.sender`, `CalendarEvent.organizer`,
  the attendee and participant joins) goes through `resolve/2` first.

  The owner rule the projectors keep holds here too: the golden is linked only
  when it has the absorbed row's owner. The people sweep only ever pairs one
  owner's people (`AshEnterprise.Mdm.People`), so that is every merge it
  makes; a merge across owners (an operator's, by hand) keeps linking the row
  the projector found, exactly as before the merge.
  """

  alias AshEnterprise.Canonical.Person

  @doc """
  The golden record for `person`: the person itself unless a merge absorbed
  it, else its master when that has the same owner. One read, and only for an
  absorbed row.
  """
  @spec resolve(Person.t() | nil, term()) :: Person.t() | nil
  def resolve(%Person{merged: true, master_id: master_id} = person, tenant)
      when is_binary(master_id) do
    case Ash.get(Person, master_id, tenant: tenant, authorize?: false, error?: false) do
      {:ok, %Person{owner_id: owner_id} = master} when owner_id == person.owner_id -> master
      _ -> person
    end
  end

  def resolve(person, _tenant), do: person
end
