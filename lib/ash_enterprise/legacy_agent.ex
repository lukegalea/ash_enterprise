defmodule AshEnterprise.LegacyAgent do
  @moduledoc """
  AshAi tool catalogue for actors working in the legacy vocabulary.

  The route selects these read-only tools explicitly. AshAi still executes each
  action with the bearer actor, so the helper cannot see beyond that actor's
  compatibility-view permissions.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAi, AshAgent.Effects.Domain]

  tools do
    tool :legacy_users, AshEnterprise.Legacy.User, :read
  end
end
