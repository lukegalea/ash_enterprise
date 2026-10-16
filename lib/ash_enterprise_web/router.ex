defmodule AshEnterpriseWeb.Router do
  use AshEnterpriseWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  # Mirrors :api. Without these the endpoint has no way to authenticate anybody:
  # every request arrives with a nil actor, the policy union grants nothing, and
  # the API answers `{"count": 0, "results": []}` to every query -- a successful
  # response containing nothing, which reads as "no data" rather than as "not
  # authenticated". Bearer only, deliberately: session auth here would make every
  # mutation reachable cross-origin.
  #
  # `AshGraphql.Plug` must run last; it reads the actor these plugs installed.
  pipeline :graphql do
    plug :load_from_bearer
    plug :set_actor, :user
    plug AshEnterpriseWeb.Plugs.LoadActorContext
    plug AshGraphql.Plug
  end

  # Content-Security-Policy for every HTML route.
  #
  # Three directives here are doing real work and cost nothing: `frame-ancestors
  # 'none'` blocks clickjacking, `object-src 'none'` kills the plugin surface, and
  # `base-uri 'self'` stops an injected <base> from re-pointing every relative URL.
  #
  # Two are weaker than they should be, and it is worth saying why rather than
  # letting a reader assume this is a considered maximum:
  #
  #   * `script-src` allows 'unsafe-inline' and 'unsafe-eval' because the mounted
  #     dev tools need them -- GraphiQL and Swagger UI both inline bootstrapping
  #     scripts, and Clarity inlines its whole bundle. All three are dev-only
  #     (`/gql/playground`, `/api/json/swaggerui`, `/clarity`), so a deployment
  #     that drops them can tighten this to `'self'` plus a per-request nonce.
  #     LiveView itself does not need either.
  #   * `style-src` allows 'unsafe-inline' because A2UI's components render into
  #     shadow DOM with their styles inlined, and because Phoenix's own error
  #     pages do the same.
  #
  # `connect-src` includes ws:/wss: because that is the LiveView socket.
  #
  # One thing that will confuse anyone comparing environments: **the header you
  # see in dev is not this string.** Tidewave rewrites it -- it adds
  # `https://tidewave.ai` to `script-src` and removes `frame-ancestors` outright,
  # because it needs to be framed. Tidewave is `only: [:dev]`, so production
  # serves exactly what is written here.
  @csp [
         "default-src 'self'",
         "img-src 'self' data: blob:",
         "font-src 'self' data:",
         "style-src 'self' 'unsafe-inline'",
         "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
         "connect-src 'self' ws: wss:",
         "frame-ancestors 'none'",
         "base-uri 'self'",
         "object-src 'none'"
       ]
       |> Enum.join("; ")

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AshEnterpriseWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
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

    # --- The launcher --------------------------------------------------------
    #
    # The front door: every surface in the registry (AshEnterprise.Surfaces),
    # grouped, with Today leading. Sign-in lands here, and the root path, the
    # old operator hub (/app/hub) and its older address (/app/demo) redirect
    # here. A signed-out visitor is bounced to /sign-in by the on_mount.
    #
    # Every surface live_session below runs `SurfaceDoor` after the sign-in
    # check: it finds the registry entry for the LiveView, checks its door
    # (the same predicate ACP checks), and assigns the grouped nav.
    ash_authentication_live_session :launcher,
      on_mount: [
        {AshEnterpriseWeb.LiveUserAuth, :live_user_required},
        AshEnterpriseWeb.SurfaceDoor
      ] do
      live "/app", LauncherLive
    end

    get "/app/hub", PageController, :launcher
    get "/app/demo", PageController, :launcher

    # The deep link every reference link carries: one record on its registry
    # surface, re-authorized as the signed-in person, then a redirect to the
    # surface with the record selected. See AshEnterpriseWeb.RecordController.
    get "/app/r/:surface/:id", RecordController, :show

    # --- A2UI surfaces -------------------------------------------------------
    #
    # Declarative, agent-renderable screens derived from resource metadata. Each
    # runs the resource's own read actions with the signed-in actor, so it is
    # filtered by the same policies as /admin and the APIs.
    #
    # Tier 3 (docs/manifesto/06-reversibility.md): removing ash_a2ui means
    # deleting lib/ash_enterprise_web/a2ui/, this live_session, and these
    # routes. Every screen has an /admin equivalent, so nothing breaks meanwhile.
    ash_authentication_live_session :a2ui_surfaces,
      on_mount: [
        {AshEnterpriseWeb.LiveUserAuth, :live_user_required},
        AshEnterpriseWeb.SurfaceDoor
      ] do
      live "/agent", AgentLive
      live "/app/users", A2uiLive.Users
      live "/app/teams", A2uiLive.Teams
      live "/app/roles", A2uiLive.Roles
      live "/app/business-units", A2uiLive.BusinessUnits
      live "/app/mdm/mappings", A2uiLive.MdmMappings
      live "/app/mdm/golden", A2uiLive.MdmGolden

      # The same people, over a table this application owns rather than a view over the legacy
      # one. Both are live, and the pair is the demonstration -- see
      # AshEnterprise.Legacy.Projection.
      live "/app/directory", A2uiLive.ProjectedUsers
    end

    # --- The daily loop (Productivity OS dogfood, epic E6) --------------------
    #
    # The operator's day. Each page is an A2UI
    # surface that the ACP server also serves (AshEnterprise.Acp), read as the
    # signed-in actor. See AshEnterpriseWeb.DailyLive.
    ash_authentication_live_session :daily_surfaces,
      on_mount: [
        {AshEnterpriseWeb.LiveUserAuth, :live_user_required},
        AshEnterpriseWeb.SurfaceDoor
      ] do
      live "/app/today", DailyLive.Today
      live "/app/calendar", DailyLive.Calendar
      live "/app/inbox", DailyLive.Inbox
      live "/app/slack", DailyLive.Slack
      live "/app/people", DailyLive.People
      live "/app/approvals", DailyLive.Approvals
      live "/app/accounts", DailyLive.Accounts

      # Operator-only (the registry's `:operator` door): erasure scopes and the
      # irreversible, typed-confirmation shred.
      live "/app/erasure", DailyLive.Erasure
    end

    ash_authentication_live_session :canonical_surfaces,
      on_mount: [
        {AshEnterpriseWeb.LiveUserAuth, :live_user_required},
        AshEnterpriseWeb.SurfaceDoor
      ] do
      live "/app/canonical-parties", A2uiLive.CanonicalParties
      live "/app/canonical-contracts", A2uiLive.CanonicalContracts
      live "/app/canonical-commitments", A2uiLive.CanonicalCommitments
    end

    ash_authentication_live_session :canonical_agent,
      on_mount: [
        {AshEnterpriseWeb.LiveUserAuth, :live_user_required},
        AshEnterpriseWeb.SurfaceDoor
      ] do
      live "/canonical/agent", CanonicalAgentLive
    end

    # --- Master data (ADR 0054) ----------------------------------------------
    #
    # The MDM demo flow's two hand-written pages: the import wizard (upload a
    # CSV, map it -- draft + AI proposal, activation stays a person's act --
    # run the batch) and the steward queue, where review-banded match
    # candidates await a person's confirm, reject or unsure. The acts are the
    # candidate's own person-gated actions; the queue only reads the System
    # One review queue and calls them. Their A2UI siblings (golden records,
    # mappings) are in :a2ui_surfaces above.
    ash_authentication_live_session :mdm_surfaces,
      on_mount: [
        {AshEnterpriseWeb.LiveUserAuth, :live_user_required},
        AshEnterpriseWeb.SurfaceDoor
      ] do
      live "/app/mdm", StewardLive
      live "/app/mdm/import", ImportLive
    end

    ash_authentication_live_session :legacy_surfaces,
      on_mount: [
        {AshEnterpriseWeb.LiveUserAuth, :live_user_required},
        AshEnterpriseWeb.SurfaceDoor
      ] do
      live "/app/legacy-users", A2uiLive.LegacyUsers
      live "/app/legacy-parties", A2uiLive.LegacyParties
      live "/app/legacy-vendor-parties", A2uiLive.LegacyVendorParties
      live "/app/legacy-enterprise-parties", A2uiLive.LegacyEnterpriseParties
      live "/app/legacy-contracting-processes", A2uiLive.LegacyContractingProcesses
      live "/app/legacy-party-roles", A2uiLive.LegacyPartyRoles
      live "/app/legacy-contracts", A2uiLive.LegacyContracts
      live "/app/legacy-contract-lines", A2uiLive.LegacyContractLines
      live "/app/legacy-commitments", A2uiLive.LegacyCommitments
    end

    ash_authentication_live_session :legacy_agent,
      on_mount: [
        {AshEnterpriseWeb.LiveUserAuth, :live_user_required},
        AshEnterpriseWeb.SurfaceDoor
      ] do
      live "/legacy/agent", LegacyAgentLive
    end

    # Compliance surfaces (ADR 0035): findings, evaluations, bundle/rule-set
    # lifecycle, catalogs and profiles. A separate live_session because these
    # sit behind the registry's `:compliance` door (AshEnterprise.Surfaces.Doors,
    # checked by SurfaceDoor) — a read grant on the compliance finding resource,
    # the same (role, privilege, depth) tuple every other governed surface
    # resolves — because the surfaces read foreign `ash_compliance` resources
    # whose access is admin-shaped.
    #
    # Tier 3, like the surfaces above: removing ash_compliance means deleting
    # lib/ash_enterprise/compliance/, lib/ash_enterprise_web/a2ui/'s
    # compliance surfaces, this live_session, and these routes.
    ash_authentication_live_session :compliance_surfaces,
      on_mount: [
        {AshEnterpriseWeb.LiveUserAuth, :live_user_required},
        AshEnterpriseWeb.SurfaceDoor
      ] do
      live "/app/compliance/findings", ComplianceA2uiLive.Findings
      live "/app/compliance/evaluations", ComplianceA2uiLive.Evaluations
      live "/app/compliance/bundles", ComplianceA2uiLive.Bundles
      live "/app/compliance/rule-sets", ComplianceA2uiLive.RuleSets
      live "/app/compliance/catalogs", ComplianceA2uiLive.Catalogs
      live "/app/compliance/profiles", ComplianceA2uiLive.Profiles
    end

    # Process and decision surfaces. A separate live_session from the A2UI one because these
    # need `:current_tenant` in assigns -- `ash_bpmn`'s LiveViews read it there, where the rest
    # of this application derives the tenant from the actor's context. The hook supplies it
    # rather than a second source of truth being assigned everywhere.
    #
    # Tier 3, like the surfaces above: removing ash_bpmn means deleting
    # lib/ash_enterprise_web/live/bpmn/, this live_session, and these routes.
    ash_authentication_live_session :process_surfaces,
      on_mount: [
        {AshEnterpriseWeb.LiveUserAuth, :live_user_required},
        {AshEnterpriseWeb.Bpmn.Helpers, :assign_tenant},
        AshEnterpriseWeb.SurfaceDoor
      ] do
      live "/app/tasks", Bpmn.TaskListLive
      live "/app/processes", Bpmn.CatalogLive, :processes
      live "/app/decisions", Bpmn.CatalogLive, :decisions
      live "/app/triggers", Bpmn.CatalogLive, :triggers
      live "/app/processes/:key/designer", Bpmn.DesignerLive
      live "/app/decisions/:key/editor", Decisions.EditorLive
      live "/app/instances/:id", Bpmn.ViewerLive
    end

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

    # The root is the launcher rather than a landing page: this hands to /app,
    # whose live session decides what happens next (the launcher for a
    # signed-in visitor, /sign-in for anyone else).
    get "/", PageController, :root
    auth_routes AuthController, AshEnterprise.Accounts.User, path: "/auth"
    sign_out_route AuthController

    # Remove these if you'd like to use your own authentication views
    sign_in_route register_path: "/register",
                  reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  on_mount: [{AshEnterpriseWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    AshEnterpriseWeb.AuthOverrides.Brand,
                    AshEnterpriseWeb.AuthOverrides,
                    Elixir.AshAuthentication.Phoenix.Overrides.Default
                  ]

    # Remove this if you do not want to use the reset password feature
    reset_route auth_routes_prefix: "/auth",
                overrides: [
                  AshEnterpriseWeb.AuthOverrides.Brand,
                  AshEnterpriseWeb.AuthOverrides,
                  Elixir.AshAuthentication.Phoenix.Overrides.Default
                ]

    # Remove this if you do not use the confirmation strategy
    confirm_route AshEnterprise.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      overrides: [
        AshEnterpriseWeb.AuthOverrides.Brand,
        AshEnterpriseWeb.AuthOverrides,
        Elixir.AshAuthentication.Phoenix.Overrides.Default
      ]

    # Remove this if you do not use the magic link strategy.
    magic_sign_in_route(AshEnterprise.Accounts.User, :magic_link,
      auth_routes_prefix: "/auth",
      overrides: [
        AshEnterpriseWeb.AuthOverrides.Brand,
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

  scope "/legacy/mcp" do
    pipe_through :mcp

    forward "/", AshAi.Mcp.Router,
      tools: [
        :legacy_users,
        :legacy_parties,
        :legacy_vendor_parties,
        :legacy_enterprise_parties,
        :legacy_contracting_processes,
        :legacy_party_roles,
        :legacy_contracts,
        :legacy_contract_lines,
        :legacy_commitments
      ],
      protocol_version_statement: "2024-11-05",
      otp_app: :ash_enterprise
  end

  scope "/canonical/mcp" do
    pipe_through :mcp

    forward "/", AshAi.Mcp.Router,
      tools: [:canonical_parties, :canonical_contracts, :canonical_commitments],
      protocol_version_statement: "2024-11-05",
      otp_app: :ash_enterprise
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

    # The canvas dev surface: the same dev-only boundary as /clarity, plus
    # the same signed-in gate every A2UI surface uses — the inspector
    # resolves objects (records included) under the signed-in actor, so the
    # screen must never be reachable anonymously.
    ash_authentication_live_session :canvas_dev_surface,
      on_mount: [
        {AshEnterpriseWeb.LiveUserAuth, :live_user_required},
        AshEnterpriseWeb.SurfaceDoor
      ] do
      scope "/", AshEnterpriseWeb do
        pipe_through :browser

        live "/canvas", CanvasLive
      end
    end
  end
end
