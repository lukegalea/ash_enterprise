defmodule AshEnterprise.Mdm.Changes.AssertFromSource do
  @moduledoc """
  On Person's `:upsert_from_source`: records what the projector just wrote as
  statements under its own source name, then refolds.

  The projector passes `statement_source` and `statement_observed_at`, the
  source object's own modified time and never the read time, so a replay is
  the same statement. A write without them states nothing; the refold's held
  values cover it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    source = Ash.Changeset.get_argument(changeset, :statement_source)
    observed_at = Ash.Changeset.get_argument(changeset, :statement_observed_at)

    if source && observed_at do
      Ash.Changeset.after_action(changeset, fn changeset, person ->
        values = %{
          "name" => Ash.Changeset.get_attribute(changeset, :name),
          "email" => Ash.Changeset.get_attribute(changeset, :email)
        }

        AshEnterprise.Mdm.Refold.assert_from_source!(
          changeset.tenant,
          person.id,
          values,
          source,
          observed_at
        )

        {:ok, Ash.get!(person.__struct__, person.id, tenant: changeset.tenant, authorize?: false)}
      end)
    else
      changeset
    end
  end
end
