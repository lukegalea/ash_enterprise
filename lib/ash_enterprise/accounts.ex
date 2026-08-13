defmodule AshEnterprise.Accounts do
  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain, AshJsonApi.Domain, AshGraphql.Domain, AshAi]

  # Exposure is opt-in per resource: a resource only appears in an API once it
  # declares a type here AND in its own `json_api` / `graphql` block. A new
  # internal resource is therefore never accidentally public.
  #
  # Note what is NOT exposed: Token (authentication plumbing) and the whole
  # Security domain (a filterable public API over the authorization tables is a
  # map of the security model). Both are reachable through the admin UI and MCP
  # tools, which run through the same policies.
  graphql do
    queries do
      get AshEnterprise.Accounts.Organization, :get_organization, :read
      list AshEnterprise.Accounts.BusinessUnit, :list_business_units, :read
      list AshEnterprise.Accounts.Team, :list_teams, :read
      list AshEnterprise.Accounts.Position, :list_positions, :read
    end
  end

  json_api do
    routes do
      base_route "/business_units", AshEnterprise.Accounts.BusinessUnit do
        get :read
        index :read
        post :create
      end

      base_route "/teams", AshEnterprise.Accounts.Team do
        get :read
        index :read
        post :create
      end

      base_route "/positions", AshEnterprise.Accounts.Position do
        get :read
        index :read
      end
    end
  end

  admin do
    show? true
  end

  # Read-only tools. An agent needs to resolve "user XYZ" to an id before it can
  # act on them, and these are how it does that -- through the same policies, so
  # it can only find users the requesting human could find.
  #
  # Reads are safe to expose broadly because Ash *filters* rather than forbids:
  # a lookup returns the subset the actor may see, never a leak and never a 403
  # that confirms a record exists.
  tools do
    tool :list_users, AshEnterprise.Accounts.User, :read do
      description "Find users. Use this to resolve a name or email to a user id."
    end

    tool :list_business_units, AshEnterprise.Accounts.BusinessUnit, :read do
      description "List business units, the hierarchy that scopes role assignments."
    end

    tool :list_teams, AshEnterprise.Accounts.Team, :read do
      description "List teams. Owner teams can hold roles; access teams cannot."
    end
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
