defmodule AshEnterprise.Legacy.Twins do
  @moduledoc """
  The legacy relations, declared verbatim as Ash resources.

  A *twin* is the old schema said out loud: columns, types, primary key, unique
  indexes and foreign keys, all read out of `pg_attribute`, `pg_index` and
  `pg_constraint` by `mix ash_strangler.gen.twin` rather than typed by anybody.
  A mapping needs them because `expr(first_name <> " " <> last_name)` has to
  resolve against something real.

  Kept out of `AshEnterprise.Legacy` on purpose: these are the schema being
  migrated *away from*, not part of the model. `AshEnterprise.Legacy.User` is
  the resource; these are what it reads.

  Everything here is generated, and a twin is a **snapshot** -- a column the
  legacy application's next migration adds is invisible to every mapping until
  it is regenerated. `mix ash_strangler.check` diffs them against
  `information_schema.columns` and says so.

  Note for whoever regenerates: the generator does not write this moduledoc, so
  it will be gone and `mix credo --strict` will say so. Put it back.
  """
  use Ash.Domain,
    otp_app: :ash_enterprise

  resources do
    resource AshEnterprise.Legacy.Twins.Companies
    resource AshEnterprise.Legacy.Twins.Users
  end
end
