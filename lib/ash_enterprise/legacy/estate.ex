defmodule AshEnterprise.Legacy.Estate do
  @moduledoc """
  The tenant the legacy estate belongs to, read off the mapping rather than
  restated next to it.

  `AshEnterprise.Legacy.User` maps `organization_id` and
  `owning_business_unit_id` to constants, because the legacy application was
  single-tenant and `company_id` was never a security boundary (plan §4.2,
  §4.3). Those constants are literals in the view's `SELECT` list, and they have
  to be: the DDL is checked in, so it cannot depend on ids a seed happened to
  generate on one machine.

  Which leaves the reverse problem — the rows those literals point at have to
  exist, and if the seed spells them out a second time then two places have to
  agree forever. So this module reads them back out of the `strangler` block.
  There is one declaration, and everything else is derived from it. Change the
  literal in the mapping, regenerate the view, and the seed follows.

  ## Both ids derive the advisory lock key `[0, 0]`, and that is accepted

  `ash_events` takes a `pg_advisory_xact_lock` before appending to the audit log,
  keyed on the tenant, and that lock is what makes the log's hash chain and its
  `sequence` ordering well defined per tenant.
  `AshEvents.AdvisoryLockKeyGenerator.Default.uuid_to_int/1` derives the key by
  splitting the uuid into two 8-byte halves and taking a `signed-32` off the
  front of each — so it samples **bytes 0-3 and 8-11 and discards 4-7 and
  12-15**.

  Every byte this estate's ids vary in is in the discarded set. Measured:

      00000000-0000-0000-0000-0000000000fe  ->  [0, 0]   # the Organization
      00000000-0000-0000-0000-0000000000fd  ->  [0, 0]   # the root BusinessUnit
      20d7dcbf-9159-4561-b69f-b00b2e47ff34  ->  [551017663, -1231048693]

  The `fe`/`fd` that distinguishes the two ids lives in byte 15, which the
  generator never reads.

  **This is harmless, and it is worth being precise about why.** A shared key
  means *more* serialization, not less, so the ordering guarantee the audit chain
  depends on is strengthened rather than weakened. What a collision costs is
  throughput: two tenants sharing a key have their audit appends serialized
  against each other. Ordinary tenants are `uuid_primary_key` — v4, random — so
  they have ~64 bits of entropy in the sampled positions and never collide in
  practice, as the third line above shows.

  **The consequence to know about is for seeding, not for production.** Any
  *further* hand-picked tenant id of the shape
  `00000000-0000-xxxx-yyyy-00000000zzzz` collides with this one, because the
  distinguishing part is in the bytes that are thrown away. If another fixed-id
  tenant is ever needed, vary bytes 0-3 or 8-11 — or just use a random uuid and
  accept that the literal is less pretty. A vanity id was the wrong instinct
  here; it was chosen to be readable in a `SELECT` list, and readability is not
  worth much next to a key that means something.

  This was found by instrumenting an actual audited write and noticing the key
  was zeros where a tenant-derived value was expected, which reading the
  generator would not have surfaced. `AshEnterprise.Legacy.EstateTest` pins the
  derivation so that if `ash_events` changes how it samples, this note is told it
  is out of date rather than quietly becoming wrong.
  """

  alias AshEnterprise.Legacy.User

  @doc "The `Organization` id every legacy row belongs to."
  @spec organization_id() :: String.t()
  def organization_id, do: constant!(:organization_id)

  @doc "The root `BusinessUnit` id every legacy row is owned by at this phase."
  @spec business_unit_id() :: String.t()
  def business_unit_id, do: constant!(:owning_business_unit_id)

  defp constant!(attribute) do
    User
    |> AshStrangler.Info.constants()
    |> Enum.find(&(&1.attribute == attribute))
    |> case do
      %{expression: %Ash.Query.Call{name: :type, args: [uuid, :uuid]}} when is_binary(uuid) ->
        uuid

      nil ->
        raise """
        #{inspect(User)} declares no `constant :#{attribute}`.

        The legacy estate's tenant is derived from the mapping, so removing that
        constant leaves nothing to seed. Either restore it or stop seeding the
        estate.
        """

      %{expression: expression} ->
        raise """
        `constant :#{attribute}` on #{inspect(User)} is no longer a plain uuid literal:

            #{inspect(expression)}

        The seed can only provision a row for an id it can read at compile time.
        If the constant has become an expression, the tenant it points at has to
        be provisioned some other way.
        """
    end
  end
end
