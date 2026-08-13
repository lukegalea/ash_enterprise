defmodule AshEnterprise.Accounts do
  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain, AshJsonApi.Domain, AshGraphql.Domain]

  graphql do
  end

  # Adding the extensions does not expose anything by itself -- a resource only
  # appears in the API once it declares a `json_api`/`graphql` type. That is
  # deliberate: exposure is opt-in per resource, so a new internal resource is
  # never accidentally public.
  json_api do
    routes do
    end
  end

  admin do
    show? true
  end

  resources do
    resource AshEnterprise.Accounts.Token
    resource AshEnterprise.Accounts.User

    # The organizational structure. Order here is documentation, not dependency:
    # Organization is the tenant, BusinessUnit is the access hierarchy inside it,
    # and Teams are the principals that hang off business units.
    resource AshEnterprise.Accounts.Organization
    resource AshEnterprise.Accounts.BusinessUnit
    resource AshEnterprise.Accounts.Team
    resource AshEnterprise.Accounts.TeamMembership

    # The job hierarchy, as distinct from the organizational one. Drives
    # hierarchy security in :position mode, which reaches across business units.
    resource AshEnterprise.Accounts.Position
  end
end
