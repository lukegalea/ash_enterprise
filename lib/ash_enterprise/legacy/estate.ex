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
