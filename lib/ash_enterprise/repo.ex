defmodule AshEnterprise.Repo do
  use AshPostgres.Repo,
    otp_app: :ash_enterprise

  @impl true
  def installed_extensions do
    # Add extensions here, and the migration generator will install them.
    [
      "ash-functions",
      "citext",
      # UUIDv7 primary keys need gen_random_uuid()-adjacent helpers; uuid-ossp
      # is the conventional companion and costs nothing to have present.
      "uuid-ossp",
      # pgvector, required by ash_ai's vectorize block.
      #
      # NOTE: this list is about `CREATE EXTENSION` in migrations, so pgvector
      # belongs here as the plain string. `AshPostgres.Extensions.Vector` is a
      # *Postgrex type* extension -- a different mechanism entirely -- and putting
      # it here fails with "function AshPostgres.Extensions.Vector.extension/0 is
      # undefined". It is wired up in AshEnterprise.PostgrexTypes and referenced
      # from the repo's `types:` config instead.
      "vector",
      AshMoney.AshPostgresExtension
    ]
  end

  # Don't open unnecessary transactions
  # will default to `false` in 4.0
  @impl true
  def prefer_transaction? do
    false
  end

  # The generator set this to whatever `postgres -V` reported on the machine
  # that ran it (17.10). That is the wrong default for a template: it makes Ash
  # emit SQL that silently requires the newest server anyone happened to have
  # installed. Declare the OLDEST server we intend to support instead, so the
  # generated migrations stay portable.
  #
  # 14 is the floor here because pgvector needs 13+, and 14 is the oldest
  # release still receiving upstream security fixes. Raise it deliberately if
  # you want a newer feature; do not raise it by accident.
  @impl true
  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end
