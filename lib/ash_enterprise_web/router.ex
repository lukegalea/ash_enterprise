defmodule AshEnterpriseWeb.Router do
  use AshEnterpriseWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :graphql do
    plug AshGraphql.Plug
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AshEnterpriseWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
    # Must run after :load_from_session -- it resolves the authorization context
    # for whatever user that installed. See the plug's moduledoc.
    plug AshEnterpriseWeb.Plugs.LoadActorContext
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
    plug AshEnterpriseWeb.Plugs.LoadActorContext
  end

  scope "/gql" do
    pipe_through [:graphql]

    forward "/playground", Absinthe.Plug.GraphiQL,
      schema: Module.concat(["AshEnterpriseWeb.GraphqlSchema"]),
      socket: Module.concat(["AshEnterpriseWeb.GraphqlSocket"]),
      interface: :simple

    forward "/", Absinthe.Plug, schema: Module.concat(["AshEnterpriseWeb.GraphqlSchema"])
  end

  scope "/api/json" do
    pipe_through [:api]

    forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/json/open_api",
      default_model_expand_depth: 4

    forward "/", AshEnterpriseWeb.AshJsonApiRouter
  end

  scope "/", AshEnterpriseWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes do
      # in each liveview, add one of the following at the top of the module:
      #
      # If an authenticated user must be present:
      # on_mount {AshEnterpriseWeb.LiveUserAuth, :live_user_required}
      #
      # If an authenticated user *may* be present:
      # on_mount {AshEnterpriseWeb.LiveUserAuth, :live_user_optional}
      #
      # If an authenticated user must *not* be present:
      # on_mount {AshEnterpriseWeb.LiveUserAuth, :live_no_user}
    end
  end

  scope "/", AshEnterpriseWeb do
    pipe_through :browser

    get "/", PageController, :home
    auth_routes AuthController, AshEnterprise.Accounts.User, path: "/auth"
    sign_out_route AuthController

    # Remove these if you'd like to use your own authentication views
    sign_in_route register_path: "/register",
                  reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  on_mount: [{AshEnterpriseWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    AshEnterpriseWeb.AuthOverrides,
                    Elixir.AshAuthentication.Phoenix.Overrides.Default
                  ]

    # Remove this if you do not want to use the reset password feature
    reset_route auth_routes_prefix: "/auth",
                overrides: [
                  AshEnterpriseWeb.AuthOverrides,
                  Elixir.AshAuthentication.Phoenix.Overrides.Default
                ]

    # Remove this if you do not use the confirmation strategy
    confirm_route AshEnterprise.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      overrides: [
        AshEnterpriseWeb.AuthOverrides,
        Elixir.AshAuthentication.Phoenix.Overrides.Default
      ]

    # Remove this if you do not use the magic link strategy.
    magic_sign_in_route(AshEnterprise.Accounts.User, :magic_link,
      auth_routes_prefix: "/auth",
      overrides: [
        AshEnterpriseWeb.AuthOverrides,
        Elixir.AshAuthentication.Phoenix.Overrides.Default
      ]
    )
  end

  # --- MCP: this application's actions as tools for external agents ------------
  #
  # This is a PRODUCT surface, not dev tooling. It exposes the same Ash actions
  # the admin UI calls, to agents acting on behalf of a real user -- see
  # docs/manifesto/05-agents-are-users.md.
  #
  # The actor is everything. An MCP endpoint reachable without one is an
  # unauthenticated API over the entire domain, so this pipeline requires a
  # bearer API key and then resolves the full authorization context, exactly as
  # the browser and JSON:API pipelines do. There is no agent-specific
  # authorization path, which is precisely why there is no agent-specific
  # authorization bug.
  pipeline :mcp do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
    plug AshEnterpriseWeb.Plugs.LoadActorContext
    plug AshEnterpriseWeb.Plugs.RequireActor
  end

  scope "/mcp" do
    pipe_through :mcp

    forward "/", AshAi.Mcp.Router,
      tools: [
        :list_users,
        :list_business_units,
        :list_teams,
        :list_roles,
        :list_privileges,
        :list_role_assignments,
        :assign_role
      ],
      # The server implements 2025-03-26, but many clients still negotiate
      # against the older statement. Advertising the older one keeps Claude
      # Desktop and similar working.
      protocol_version_statement: "2024-11-05",
      otp_app: :ash_enterprise
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ash_enterprise, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AshEnterpriseWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  if Application.compile_env(:ash_enterprise, :dev_routes) do
    import AshAdmin.Router

    scope "/admin" do
      pipe_through :browser

      ash_admin "/"
    end
  end

  if Application.compile_env(:ash_enterprise, :dev_routes) do
    import Clarity.Router

    scope "/clarity" do
      pipe_through :browser

      clarity "/"
    end
  end
end
