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
  end
end
