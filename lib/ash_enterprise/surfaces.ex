defmodule AshEnterprise.Surfaces do
  @moduledoc """
  The surface registry: every screen this application serves, declared once.

  Everything that needs to know "what surfaces exist" derives from the list
  below rather than keeping its own copy:

    * the web nav (grouped menus) and the `/app` launcher;
    * the web door (`AshEnterpriseWeb.SurfaceDoor`), which finds the entry for
      the LiveView being mounted and checks its `door`;
    * the ACP grammar (`AshEnterprise.Acp.Commands`), which opens any entry by
      its command and refuses one whose door is closed;
    * the ACP command palette (`candidate_actions/0`) and the `help` text;
    * the helper agent's catalogue (`catalogue/0`, `names/0`, `helper/0`);
    * reference links and deep links: the surface that shows one record of a
      resource (`record_surface/2`), which the link resolver
      (`AshEnterprise.Surfaces.LinkResolver`), the web's `/app/r/:surface/:id`
      and ACP's `_ash/surface/open` all open through
      `AshEnterprise.Surfaces.Records`.

  ## Why it lives here and not under `AshEnterpriseWeb`

  Two transports serve these surfaces — the web and ACP — and ACP lives in
  `lib/ash_enterprise/acp`. A registry owned by the web would make the
  terminal a client of the web layer for a fact (which screens exist, who may
  open them) that belongs to neither. So the registry is neutral; it names web
  modules (`live`, `ui`) as plain atoms, which is a runtime reference only.
  The doors are neutral for the same reason (`AshEnterprise.Surfaces.Doors`):
  one predicate, enforced by both transports.

  ## Topics are derived, never spelled

  `topics/1` reads a surface's PubSub topics off its resource's `pub_sub`
  publications, so a live surface's subscription has one declaration. A
  resource that publishes nothing yields `[]` and the surface is simply not
  live.
  """

  alias AshEnterprise.Agents.{Console, MorningBrief}
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Surfaces.{Doors, Surface}
  alias AshEnterpriseWeb.A2ui
  alias AshEnterpriseWeb.A2uiLive
  alias AshEnterpriseWeb.ComplianceA2uiLive
  alias AshEnterpriseWeb.DailyLive

  @groups [
    %{
      key: :day,
      label: "My day",
      menu: :day,
      blurb: "Your calendar, mail, people and the approvals waiting on you."
    },
    %{
      key: :operator,
      label: "Operator",
      menu: :day,
      blurb: "Linked accounts, their syncs, erasure, lineage and the audit trail."
    },
    %{
      key: :processes,
      label: "Processes",
      menu: :work,
      blurb: "The processes this tenant runs, the decisions they consult, and what starts them."
    },
    %{
      key: :compliance,
      label: "Compliance",
      menu: :work,
      blurb: "Findings, the evaluations behind them, and the rules they are judged against."
    },
    %{
      key: :org,
      label: "Organization",
      menu: :org,
      blurb: "Who can sign in, the teams and units they belong to, and their roles."
    },
    %{
      key: :data,
      label: "Projections",
      menu: :data,
      blurb: "Tables this application owns, projected from elsewhere."
    },
    %{
      key: :mdm,
      label: "Master data",
      menu: :data,
      blurb:
        "Customer files imported, matched into golden records, and the matches a person decides."
    },
    %{
      key: :legacy,
      label: "Legacy",
      menu: :data,
      blurb: "The old system, read live through compatibility views."
    }
  ]

  @menus [day: "My day", work: "Work", org: "Organization", data: "Data"]

  @surfaces [
    # --- My day -------------------------------------------------------------
    %Surface{
      key: :today,
      label: "Today",
      blurb: "Your morning brief, today's agenda and the day's pulse.",
      group: :day,
      order: 0,
      icon: "hero-sun",
      path: "/app/today",
      live: DailyLive.Today,
      ui: A2ui.TodayUI,
      resource: MorningBrief,
      context: :brief,
      acp: %{
        command: "today",
        aliases: ["day"],
        action: {Console, :today},
        description: "Your day: agenda, morning brief, approvals, sync health",
        palette?: true,
        verbs: [
          %{
            command: "compose",
            action: {MorningBrief, :compose_today},
            hint: "brief",
            description: "Compose today's morning brief, if you have none yet (asks first)"
          }
        ]
      }
    },
    %Surface{
      key: :agent,
      label: "Agent",
      blurb:
        "Ask about your calendar, mail, Slack, people and approvals. Answers cite the " <>
          "records they came from; the model runs in the zone.",
      group: :day,
      order: 5,
      icon: "hero-sparkles",
      path: "/app/agent",
      live: AshEnterpriseWeb.AssistantLive,
      resource: AshEnterprise.Assistant.Thread
    },
    %Surface{
      key: :calendar,
      label: "Calendar",
      blurb:
        "Your events on a month or week grid, with today, tomorrow, this week and the " <>
          "next two weeks as quick ranges.",
      group: :day,
      order: 10,
      icon: "hero-calendar-days",
      path: "/app/calendar",
      live: DailyLive.Calendar,
      ui: A2ui.CalendarUI,
      resource: AshEnterprise.Canonical.CalendarEvent,
      context: :event,
      acp: %{
        command: "calendar",
        aliases: ["agenda"],
        params: [window: {:one_of, ~w(today tomorrow week upcoming)}],
        action: {Console, :agenda},
        description: "Agenda for a window",
        palette?: true
      }
    },
    %Surface{
      key: :inbox,
      label: "Inbox",
      blurb: "Gmail threads, newest first.",
      group: :day,
      order: 20,
      icon: "hero-envelope",
      path: "/app/inbox",
      live: DailyLive.Inbox,
      ui: A2ui.InboxUI,
      resource: AshEnterprise.Canonical.Conversation,
      context: :thread,
      record_match: [external_system: "gmail"],
      acp: %{
        command: "inbox",
        aliases: ["mail", "gmail"],
        action: {Console, :inbox},
        description: "Gmail threads, newest first",
        palette?: true
      }
    },
    %Surface{
      key: :slack,
      label: "Slack",
      blurb: "Slack channels, group DMs and DMs, newest first.",
      group: :day,
      order: 30,
      icon: "hero-chat-bubble-left-right",
      path: "/app/slack",
      live: DailyLive.Slack,
      ui: A2ui.SlackUI,
      resource: AshEnterprise.Canonical.Conversation,
      context: :conversation,
      record_match: [external_system: "slack"],
      acp: %{
        command: "slack",
        action: {Console, :inbox},
        description: "Slack conversations, newest first",
        palette?: true
      }
    },
    %Surface{
      key: :people,
      label: "People",
      blurb: "Everyone you correspond and meet with, and their events.",
      group: :day,
      order: 40,
      icon: "hero-user-circle",
      path: "/app/people",
      live: DailyLive.People,
      ui: A2ui.PeopleUI,
      resource: AshEnterprise.Canonical.Person,
      context: :person,
      acp: %{
        command: "people",
        params: [search: :string],
        action: {Console, :people},
        description: "The people directory",
        palette?: true
      }
    },
    # PROD-18: one list of what the person has to do. `todo` alone opens it,
    # `todo <text>` captures into the Inbox, `done N` finishes the Nth item
    # of the `todo` list (AshEnterprise.Acp.Commands).
    %Surface{
      key: :action_items,
      label: "Action items",
      blurb:
        "Everything you have to do: captured items in Inbox, Today, Later and Done, " <>
          "with the process tasks waiting on you beside them.",
      group: :day,
      order: 45,
      icon: "hero-check-circle",
      path: "/app/action-items",
      live: DailyLive.ActionItems,
      ui: A2ui.ActionItemsUI,
      resource: AshEnterprise.Canonical.Task,
      context: :item,
      acp: %{
        command: "todo",
        aliases: ["todos", "to do", "action items"],
        params: [text: :string],
        action: {Console, :action_items},
        description: "Your action items, numbered; `todo <text>` captures one",
        palette?: true,
        verbs: [
          %{
            command: "done",
            action: {Console, :done},
            hint: "N",
            description: "Mark the Nth action item of `todo` done"
          }
        ]
      }
    },
    %Surface{
      key: :approvals,
      label: "Approvals",
      blurb: "The tasks waiting on your decision.",
      group: :day,
      order: 50,
      icon: "hero-check-badge",
      path: "/app/approvals",
      live: DailyLive.Approvals,
      ui: A2ui.ApprovalsUI,
      resource: HumanTask,
      context: :task,
      acp: %{
        command: "approvals",
        aliases: ["tasks"],
        action: {Console, :approvals},
        description: "Tasks waiting on you, numbered",
        palette?: true,
        verbs: [
          %{
            command: "approve",
            action: {HumanTask, :approve},
            hint: "N | brief",
            description: "Approve a waiting task (asks first)"
          },
          %{
            command: "reject",
            action: {HumanTask, :reject},
            hint: "N | brief",
            description: "Reject a waiting task (asks first)"
          }
        ]
      }
    },

    # --- Operator -------------------------------------------------------------
    %Surface{
      key: :accounts,
      label: "Accounts & syncs",
      blurb: "Your linked accounts and how their syncs are doing.",
      group: :operator,
      order: 0,
      icon: "hero-arrow-path",
      path: "/app/accounts",
      live: DailyLive.Accounts,
      ui: A2ui.AccountsUI,
      resource: LinkedAccount,
      context: :account,
      acp: %{
        command: "accounts",
        aliases: ["syncs", "sync status"],
        action: {Console, :accounts},
        description: "Linked accounts and sync health",
        palette?: true,
        verbs: [
          %{
            command: "sync",
            action: {LinkedAccount, :sync_now},
            hint: "calendar | gmail | slack",
            description: "Sync an account now (asks first)"
          }
        ]
      }
    },
    %Surface{
      key: :erasure,
      label: "Erasure scopes",
      blurb: "Erasure scopes and the irreversible, typed-confirmation shred.",
      group: :operator,
      order: 10,
      icon: "hero-trash",
      path: "/app/erasure",
      live: DailyLive.Erasure,
      ui: A2ui.ErasureUI,
      resource: AshEnterprise.Erasure.Scope,
      context: :scope,
      door: :operator,
      acp: %{
        command: "erasure",
        aliases: ["scopes", "erasure scopes"],
        action: {AshEnterprise.Erasure.Scope, :scopes_digest},
        description: "Erasure scopes (read-only; shred is web-only)",
        palette?: true,
        ui: A2ui.ErasureReadOnlyUI
      }
    },
    %Surface{
      key: :lineage,
      label: "Lineage",
      blurb: "What ran, what it read and wrote, and what failed, drawn as a live graph.",
      description:
        "The lineage graph: every job (syncs, projections, writes) and the datasets it " <>
          "reads and writes, with failed and running runs marked, and each run's audit " <>
          "entries. Ask for this when the request is about what ran, a failed sync, or " <>
          "where data came from.",
      group: :operator,
      order: 20,
      icon: "hero-share",
      path: "/app/lineage",
      live: AshEnterpriseWeb.LineageLive,
      ui: A2ui.LineageUI,
      resource: AshEnterprise.Lineage.Run,
      context: :run,
      door: :lineage,
      acp: %{
        command: "lineage",
        aliases: ["runs", "what ran"],
        params: [window: {:one_of, ~w(hour day week fortnight)}],
        action: {Console, :lineage},
        description: "Lineage: failed and running runs, then each job's latest",
        palette?: true
      }
    },
    %Surface{
      key: :audit,
      label: "Audit trail",
      blurb: "Every recorded change, newest first, each linked to the run that made it.",
      group: :operator,
      order: 30,
      icon: "hero-clipboard-document-list",
      path: "/app/audit",
      live: AshEnterpriseWeb.AuditLive,
      ui: A2ui.AuditUI,
      resource: AshEnterprise.Audit.EventLog,
      context: :entry,
      door: :audit,
      acp: %{command: "audit trail", aliases: ["audit"]}
    },

    # --- Processes ----------------------------------------------------------
    %Surface{
      key: :tasks,
      label: "My tasks",
      blurb: "Every process task routed to you: claim it, complete it, or hand it on.",
      group: :processes,
      order: 0,
      icon: "hero-inbox-stack",
      path: "/app/tasks",
      live: A2uiLive.Tasks,
      ui: A2ui.TaskBoardUI,
      resource: HumanTask,
      context: :task,
      acp: %{command: "my tasks"}
    },
    # The flight views (PROD-10): a process drawn with a marker on every step a
    # run is standing on. `:flight` is the first surface over Instance with a
    # detail, so every link to a run (`link :instance`, `link :process_run`)
    # opens there; the two process views list every run of one process.
    %Surface{
      key: :flight,
      label: "Flight view",
      blurb: "One process run on its diagram, with a marker on the step it is on now.",
      group: :processes,
      order: 5,
      icon: "hero-map",
      path: "/app/flights",
      live: AshEnterpriseWeb.FlightLive.Instance,
      ui: A2ui.FlightUI,
      resource: AshEnterprise.Bpmn.Instance,
      context: :instance,
      acp: %{command: "flight", aliases: ["flight view"]}
    },
    %Surface{
      key: :brief_flight,
      label: "Brief approvals in flight",
      blurb: "Every running morning brief, on the step it is on now.",
      group: :processes,
      order: 6,
      icon: "hero-sun",
      path: "/app/flights/briefs",
      live: AshEnterpriseWeb.FlightLive.Briefs,
      ui: A2ui.BriefFlightUI,
      resource: AshEnterprise.Bpmn.Instance,
      acp: %{command: "brief flight", aliases: ["briefs in flight"]}
    },
    %Surface{
      key: :steward_flight,
      label: "Stewardship in flight",
      blurb: "Every match under steward review, on the step it is on now.",
      group: :processes,
      order: 7,
      icon: "hero-hand-raised",
      path: "/app/flights/stewardship",
      live: AshEnterpriseWeb.FlightLive.Stewardship,
      ui: A2ui.StewardFlightUI,
      resource: AshEnterprise.Bpmn.Instance,
      acp: %{command: "stewardship flight", aliases: ["steward flight"]}
    },
    %Surface{
      key: :processes,
      label: "Processes",
      blurb: "Every BPMN process this tenant can run: baselines and its own customizations.",
      group: :processes,
      order: 10,
      icon: "hero-square-3-stack-3d",
      path: "/app/processes",
      live: AshEnterpriseWeb.Bpmn.CatalogLive,
      live_action: :processes,
      resource: AshEnterprise.Bpmn.Definition,
      acp: %{command: "processes"}
    },
    %Surface{
      key: :decisions,
      label: "Decisions",
      blurb: "The DMN decisions processes route on, resolved when they are asked.",
      group: :processes,
      order: 20,
      icon: "hero-table-cells",
      path: "/app/decisions",
      live: AshEnterpriseWeb.Bpmn.CatalogLive,
      live_action: :decisions,
      resource: AshEnterprise.Decisions.Definition,
      acp: %{command: "decisions"}
    },
    %Surface{
      key: :triggers,
      label: "Triggers",
      blurb: "What starts a process: a watched write, a guard, and what it starts.",
      group: :processes,
      order: 30,
      icon: "hero-bolt",
      path: "/app/triggers",
      live: AshEnterpriseWeb.Bpmn.CatalogLive,
      live_action: :triggers,
      resource: AshEnterprise.Bpmn.Subscription,
      acp: %{command: "triggers"}
    },

    # --- Compliance (ADR 0035) -----------------------------------------------
    %Surface{
      key: :findings,
      label: "Findings",
      blurb: "Who is breaching which control, and why.",
      group: :compliance,
      order: 0,
      icon: "hero-shield-exclamation",
      path: "/app/compliance/findings",
      live: ComplianceA2uiLive.Findings,
      ui: A2ui.FindingUI,
      resource: AshCompliance.Resources.Finding,
      door: :compliance,
      acp: %{command: "findings"}
    },
    %Surface{
      key: :evaluations,
      label: "Evaluations",
      blurb: "The append-only log of what the engine decided, and on what facts.",
      group: :compliance,
      order: 10,
      icon: "hero-clipboard-document-check",
      path: "/app/compliance/evaluations",
      live: ComplianceA2uiLive.Evaluations,
      ui: A2ui.ComplianceEvaluationUI,
      resource: AshCompliance.Resources.ComplianceEvaluation,
      door: :compliance,
      acp: %{command: "evaluations"}
    },
    %Surface{
      key: :rule_sets,
      label: "Rule sets",
      blurb: "Rule set revisions: their layer, lifecycle and content hash.",
      group: :compliance,
      order: 20,
      icon: "hero-scale",
      path: "/app/compliance/rule-sets",
      live: ComplianceA2uiLive.RuleSets,
      ui: A2ui.RuleSetRevisionUI,
      resource: AshCompliance.Resources.RuleSetRevision,
      door: :compliance,
      acp: %{command: "rule sets"}
    },
    %Surface{
      key: :bundles,
      label: "Policy bundles",
      blurb: "Compiled bundles: which is active for whom, and since when.",
      group: :compliance,
      order: 30,
      icon: "hero-archive-box",
      path: "/app/compliance/bundles",
      live: ComplianceA2uiLive.Bundles,
      ui: A2ui.PolicyBundleUI,
      resource: AshCompliance.Resources.PolicyBundle,
      door: :compliance,
      acp: %{command: "bundles", aliases: ["policy bundles"]}
    },
    %Surface{
      key: :catalogs,
      label: "Catalogs",
      blurb: "Compliance catalogs, and the OSCAL documents they came from.",
      group: :compliance,
      order: 40,
      icon: "hero-book-open",
      path: "/app/compliance/catalogs",
      live: ComplianceA2uiLive.Catalogs,
      ui: A2ui.CatalogUI,
      resource: AshCompliance.Resources.Catalog,
      context: :catalog,
      door: :compliance,
      acp: %{command: "catalogs"}
    },
    %Surface{
      key: :profiles,
      label: "Profiles",
      blurb: "Tailoring profiles: who tailored what, against which catalog.",
      group: :compliance,
      order: 50,
      icon: "hero-adjustments-horizontal",
      path: "/app/compliance/profiles",
      live: ComplianceA2uiLive.Profiles,
      ui: A2ui.ProfileUI,
      resource: AshCompliance.Resources.Profile,
      door: :compliance,
      acp: %{command: "profiles"}
    },

    # --- Organization ------------------------------------------------------------
    %Surface{
      key: :users,
      label: "Users",
      blurb: "People with accounts in this application.",
      description:
        "People with accounts in this application, with their status and sign-up date.",
      group: :org,
      order: 0,
      icon: "hero-users",
      path: "/app/users",
      live: A2uiLive.Users,
      ui: A2ui.UserUI,
      resource: AshEnterprise.Accounts.User,
      context: :user,
      acp: %{command: "users"}
    },
    %Surface{
      key: :teams,
      label: "Teams",
      blurb: "Teams, which own records alongside users.",
      description: "Teams, which own records alongside users in the polymorphic ownership model.",
      group: :org,
      order: 10,
      icon: "hero-user-group",
      path: "/app/teams",
      live: A2uiLive.Teams,
      ui: A2ui.TeamUI,
      resource: AshEnterprise.Accounts.Team,
      context: :team,
      acp: %{command: "teams"}
    },
    %Surface{
      key: :roles,
      label: "Roles",
      blurb: "Named bundles of privileges a user can hold.",
      description: "Security roles, which are the named bundles of privileges a user can hold.",
      group: :org,
      order: 20,
      icon: "hero-key",
      path: "/app/roles",
      live: A2uiLive.Roles,
      ui: A2ui.RoleUI,
      resource: AshEnterprise.Security.Role,
      acp: %{command: "roles"}
    },
    %Surface{
      key: :business_units,
      label: "Business units",
      blurb: "The hierarchy that authorization depth expands over.",
      description: "The business-unit hierarchy that authorization depth expands over.",
      group: :org,
      order: 30,
      icon: "hero-building-office-2",
      path: "/app/business-units",
      live: A2uiLive.BusinessUnits,
      ui: A2ui.BusinessUnitUI,
      resource: AshEnterprise.Accounts.BusinessUnit,
      context: :business_unit,
      acp: %{command: "business units"}
    },

    # --- Projections -----------------------------------------------------------
    %Surface{
      key: :directory,
      label: "Directory",
      blurb: "The legacy estate's people, projected into a table this application owns.",
      group: :data,
      order: 0,
      icon: "hero-identification",
      path: "/app/directory",
      live: A2uiLive.ProjectedUsers,
      ui: A2ui.ProjectedUserUI,
      resource: AshEnterprise.Accounts.ProjectedUser,
      acp: %{command: "directory"}
    },

    # --- Master data (ADR 0054) -------------------------------------------------
    # The steward's verdict is a person's act: the candidate's :confirm,
    # :reject and :escalate actions refuse system and AI actors by policy, so
    # the queue opens to any signed-in person and the policies decide what
    # they may read and act on.
    %Surface{
      key: :steward,
      label: "Steward queue",
      blurb: "Review-banded matches awaiting a person's confirm, reject or unsure.",
      group: :mdm,
      order: 0,
      icon: "hero-hand-raised",
      path: "/app/mdm",
      live: A2uiLive.MdmSteward,
      ui: A2ui.MdmStewardUI,
      resource: AshEnterprise.Mdm.MatchCandidate,
      context: :candidate,
      acp: %{command: "steward queue", aliases: ["steward"]}
    },
    %Surface{
      key: :mdm_import,
      label: "Import CSV",
      blurb: "Upload a customer file, map its columns onto the golden record, run the import.",
      group: :mdm,
      order: 10,
      icon: "hero-arrow-up-tray",
      path: "/app/mdm/import",
      live: AshEnterpriseWeb.ImportLive,
      resource: AshEnterprise.Mdm.ImportBatch,
      acp: %{command: "import csv", aliases: ["mdm import"]}
    },
    %Surface{
      key: :mdm_golden,
      label: "Golden records",
      blurb: "The merged view of the customer, with merge lineage.",
      description:
        "Golden records (canonical people) built by the MDM pipeline, with each row's " <>
          "merge lineage readable: who absorbed whom, pointing at whom.",
      group: :mdm,
      order: 20,
      icon: "hero-star",
      path: "/app/mdm/golden",
      live: A2uiLive.MdmGolden,
      ui: A2ui.MdmGoldenUI,
      resource: AshEnterprise.Canonical.Person,
      # People is the first surface over Person, so a plain person link opens
      # there; links that name this surface (`{:mdm_golden, ...}`) open here.
      context: :person,
      acp: %{command: "golden records", aliases: ["goldens"]}
    },
    %Surface{
      key: :mdm_mappings,
      label: "MDM mappings",
      blurb: "The mapping version chain: no-deploy onboarding.",
      description:
        "Versioned schema mappings (ADR 0054): draft → validate → activate, one per " <>
          "customer schema. Activation supersedes; nothing is overwritten.",
      group: :mdm,
      order: 30,
      icon: "hero-arrows-right-left",
      path: "/app/mdm/mappings",
      live: A2uiLive.MdmMappings,
      ui: A2ui.MdmMappingUI,
      resource: AshEnterprise.Mdm.Mapping,
      context: :mapping,
      acp: %{command: "mdm mappings", aliases: ["mappings"]}
    },
    %Surface{
      key: :mdm_batches,
      label: "Import batches",
      blurb: "Every import by status, with its counts and its staged rows.",
      description:
        "MDM import batches (ADR 0054) as a board by status — open, staging, matching, " <>
          "review, closed, failed — each with its counters, failure reason, pinned mapping " <>
          "and staged rows.",
      group: :mdm,
      order: 40,
      icon: "hero-rectangle-stack",
      path: "/app/mdm/batches",
      live: A2uiLive.MdmBatches,
      ui: A2ui.MdmBatchUI,
      resource: AshEnterprise.Mdm.ImportBatch,
      context: :batch,
      acp: %{command: "import batches", aliases: ["batches"]}
    },

    # --- Legacy ------------------------------------------------------------------
    %Surface{
      key: :legacy_users,
      label: "Legacy users",
      blurb: "The old system's people, read live through a compatibility view.",
      description:
        "People in the OLD system — a 2010-era Rails schema, read through a compatibility " <>
          "view. Ask for these when the request mentions the legacy system, the old " <>
          "application, or migrated data. This surface updates itself when the legacy " <>
          "application writes.",
      group: :legacy,
      order: 0,
      icon: "hero-user",
      path: "/app/legacy-users",
      live: A2uiLive.LegacyUsers,
      ui: A2ui.LegacyUserUI,
      resource: AshEnterprise.Legacy.User,
      acp: %{command: "legacy users"}
    }
  ]

  @group_rank @groups |> Enum.with_index() |> Map.new(fn {g, i} -> {g.key, i} end)
  @sorted Enum.sort_by(@surfaces, &{Map.fetch!(@group_rank, &1.group), &1.order})
  @by_key Map.new(@sorted, &{&1.key, &1})

  # -- reading the registry ---------------------------------------------------

  @doc "Every surface, in group order then `order`."
  @spec all() :: [Surface.t()]
  def all, do: @sorted

  @doc "The groups, in display order: `%{key, label, menu, blurb}`."
  @spec groups() :: [map()]
  def groups, do: @groups

  @doc "The nav menus the groups fold into, in order: `[{menu, label}]`."
  @spec menus() :: keyword(String.t())
  def menus, do: @menus

  @doc """
  The surface for `key` (an atom), or a name a person or model typed
  (`"Legacy Users"`, `"legacy-users"`, `"legacy_users"`). `nil` when none.
  """
  @spec fetch(atom() | String.t() | nil) :: Surface.t() | nil
  def fetch(nil), do: nil
  def fetch(key) when is_atom(key), do: Map.get(@by_key, key)

  def fetch(name) when is_binary(name) do
    normalized = name |> String.trim() |> String.downcase() |> String.replace(~r/[\s-]+/, "_")
    Enum.find(@sorted, &(Atom.to_string(&1.key) == normalized))
  end

  @doc "Like `fetch/1`, raising when there is no such surface."
  @spec fetch!(atom() | String.t()) :: Surface.t()
  def fetch!(key), do: fetch(key) || raise(ArgumentError, "no surface #{inspect(key)}")

  @doc "The surface served at a web path, or `nil`."
  @spec by_path(String.t()) :: Surface.t() | nil
  def by_path(path), do: Enum.find(@sorted, &(&1.path == path))

  @doc "The surface a LiveView (and live action) serves, or `nil`."
  @spec by_live(module(), atom() | nil) :: Surface.t() | nil
  def by_live(view, action \\ nil) do
    Enum.find(@sorted, &(&1.live == view and &1.live_action in [nil, action])) ||
      Enum.find(@sorted, &(&1.live == view))
  end

  @doc "The surface rendering an `AshA2ui` UI module (web or ACP), or `nil`."
  @spec by_ui(module()) :: Surface.t() | nil
  def by_ui(ui), do: Enum.find(@sorted, &(&1.ui == ui or acp_ui(&1) == ui))

  @doc """
  The surfaces that can open one record of `resource` in detail — those over
  `resource` that declare a `context`. A link to a record goes to the first.
  """
  @spec for_resource(module()) :: [Surface.t()]
  def for_resource(resource),
    do: Enum.filter(@sorted, &(&1.resource == resource and not is_nil(&1.context)))

  @doc """
  The surface that shows one record of `resource` in detail (the first of
  `for_resource/1`), or `nil`. With a `record`, the surface whose
  `record_match` the record satisfies — a Slack conversation opens in Slack,
  a Gmail thread in the Inbox — falling back to the first.
  """
  @spec record_surface(module(), struct() | nil) :: Surface.t() | nil
  def record_surface(resource, record \\ nil)

  def record_surface(resource, nil), do: resource |> for_resource() |> List.first()

  def record_surface(resource, record) do
    candidates = for_resource(resource)

    Enum.find(candidates, &(&1.record_match != [] and matches?(&1.record_match, record))) ||
      Enum.find(candidates, &(&1.record_match == [])) ||
      List.first(candidates)
  end

  @doc """
  Whether `surface` shows `record` as its own: its `record_match` is empty
  or the record satisfies it.
  """
  @spec admits?(Surface.t(), struct()) :: boolean()
  def admits?(%Surface{record_match: []}, _record), do: true
  def admits?(%Surface{record_match: match}, record), do: matches?(match, record)

  defp matches?(match, record),
    do: Enum.all?(match, fn {attribute, value} -> Map.get(record, attribute) == value end)

  @doc "The surfaces whose door is open for `actor`."
  @spec visible(term()) :: [Surface.t()]
  def visible(actor), do: Enum.filter(@sorted, &open?(&1, actor))

  @doc """
  The groups with the surfaces `actor` may open, empty groups dropped:
  `[%{key, label, menu, blurb, surfaces: [Surface.t()]}]`.
  """
  @spec grouped(term()) :: [map()]
  def grouped(actor) do
    visible = visible(actor)

    @groups
    |> Enum.map(fn group ->
      Map.put(group, :surfaces, Enum.filter(visible, &(&1.group == group.key)))
    end)
    |> Enum.reject(&(&1.surfaces == []))
  end

  @doc "Whether `actor` may open `surface`: its door (`AshEnterprise.Surfaces.Doors`)."
  @spec open?(Surface.t(), term()) :: boolean()
  def open?(%Surface{door: door}, actor), do: Doors.open?(door, actor)

  # -- ACP ---------------------------------------------------------------------

  @doc "The UI module ACP renders for `surface` (its `acp.ui` override, else `ui`)."
  @spec acp_ui(Surface.t()) :: module() | nil
  def acp_ui(%Surface{acp: %{ui: ui}}) when not is_nil(ui), do: ui
  def acp_ui(%Surface{ui: ui}), do: ui

  @doc """
  The surface an ACP prompt names, and the rest of the prompt:
  `{surface, rest}` or `nil`. Matches the longest command or alias that the
  (normalized, lower-case) text starts with, at a word boundary.
  """
  @spec match_command(String.t()) :: {Surface.t(), String.t()} | nil
  def match_command(text) do
    commands()
    |> Enum.filter(fn {word, _surface} ->
      text == word or String.starts_with?(text, word <> " ")
    end)
    |> Enum.max_by(fn {word, _surface} -> String.length(word) end, fn -> nil end)
    |> case do
      nil -> nil
      {word, surface} -> {surface, text |> String.replace_prefix(word, "") |> String.trim()}
    end
  end

  @doc "Every ACP command word (commands and aliases) with its surface."
  @spec commands() :: [{String.t(), Surface.t()}]
  def commands do
    for %Surface{acp: %{command: command} = acp} = surface <- @sorted,
        word <- [command | Map.get(acp, :aliases, [])],
        do: {word, surface}
  end

  @doc """
  The ACP palette (`config :ash_acp, :candidate_actions` shape), derived:
  each palette surface's command and its verbs, then `open` and `help`.
  `ash_acp` prunes it per actor with `Ash.can?/3` on each `action`.
  """
  @spec candidate_actions() :: [map()]
  def candidate_actions do
    palette =
      for %Surface{acp: %{palette?: true} = acp} <- @sorted,
          entry <- [Map.put(acp, :hint, hint(acp)) | Map.get(acp, :verbs, [])],
          do: candidate(entry)

    palette ++
      [
        candidate(%{
          command: "open",
          action: {Console, :open},
          hint: "<surface> — `help` lists yours",
          description: "Open any surface by name"
        }),
        candidate(%{command: "help", action: {Console, :help}, description: "This list"})
      ]
  end

  defp candidate(entry) do
    base = %{action: entry.action, name: entry.command, description: entry.description}

    case entry[:hint] do
      nil -> base
      hint -> Map.put(base, :input, %{"hint" => hint})
    end
  end

  @doc "The palette hint for an ACP spec, derived from its `params`."
  @spec hint(map()) :: String.t() | nil
  def hint(%{params: [{_name, {:one_of, values}}]}), do: Enum.join(values, " | ")
  def hint(%{params: [{name, :string}]}), do: "[#{name}]"
  def hint(_acp), do: nil

  # -- the helper agent ----------------------------------------------------------

  @doc "The surfaces the helper agent may host: those with a model-facing `description`."
  @spec helper() :: [Surface.t()]
  def helper, do: Enum.filter(@sorted, &(&1.description && &1.ui))

  @doc """
  The helper-hostable surface named `name` (as `fetch/1` reads names), when
  its door is open for `actor`; else `nil`. What the helper calls instead of
  `fetch/1`, so neither a model nor a button can host a surface it may not.
  """
  @spec fetch_helper(atom() | String.t() | nil, term()) :: Surface.t() | nil
  def fetch_helper(name, actor) do
    with %Surface{} = surface <- fetch(name),
         true <- surface in helper() and open?(surface, actor) do
      surface
    else
      _ -> nil
    end
  end

  @doc "The surface names a model may choose between."
  @spec names() :: [String.t()]
  def names, do: Enum.map(helper(), &Atom.to_string(&1.key))

  @doc """
  The helper's catalogue as prose, for a prompt. Uses `description`, not
  `blurb`: the description tells a *model* when to pick a surface, and
  putting that on screen reads as the application talking to itself.
  """
  @spec catalogue() :: String.t()
  def catalogue do
    Enum.map_join(helper(), "\n", &"  - #{&1.key}: #{&1.description}")
  end

  # -- live surfaces --------------------------------------------------------------

  @doc """
  The Phoenix.PubSub topics a surface (or UI module) should subscribe to,
  read off its resource's `Ash.Notifier.PubSub` publications. `[]` when the
  resource publishes nothing.
  """
  @spec topics(Surface.t() | module() | nil) :: [String.t()]
  def topics(%Surface{ui: nil}), do: []
  def topics(%Surface{ui: ui}), do: topics(ui)
  def topics(nil), do: []

  def topics(module) when is_atom(module) do
    resource =
      if Spark.Dsl.is?(module, Ash.Resource), do: module, else: AshA2ui.Info.resource!(module)

    if Ash.Notifier.PubSub in Ash.Resource.Info.notifiers(resource) do
      prefix = Ash.Notifier.PubSub.Info.prefix(resource)

      resource
      |> Ash.Notifier.PubSub.Info.publications()
      |> Enum.flat_map(fn publication ->
        publication.topic |> List.wrap() |> Enum.map(&topic_string(prefix, &1))
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    else
      []
    end
  end

  # A segment carrying an interpolated field (`[:id, "updated"]`) cannot be
  # subscribed to without knowing the value, so it is skipped rather than
  # subscribed to under a wrong name.
  defp topic_string(prefix, segment) when is_binary(segment),
    do: if(prefix, do: "#{prefix}:#{segment}", else: segment)

  defp topic_string(_prefix, _segment), do: nil

  @doc "Whether a surface refreshes itself when its rows change."
  @spec live?(Surface.t() | module()) :: boolean()
  def live?(surface), do: topics(surface) != []

  @doc """
  The `AshA2ui.LiveRenderer` config for hosting `surface` at runtime (the
  helper does not know at compile time which surface it will show).
  """
  @spec renderer_config(Surface.t(), keyword()) :: map()
  def renderer_config(%Surface{} = surface, opts) do
    AshA2ui.LiveRenderer.build_config(
      ui: surface.ui,
      actor_fn: fn _socket -> opts[:actor] end,
      tenant_fn: fn _socket -> opts[:tenant] end,
      pubsub:
        case topics(surface) do
          [] -> nil
          topics -> [module: AshEnterprise.PubSub, topics: topics]
        end
    )
  end

  @doc """
  The resources the helper agent may compose an ad-hoc surface over: an
  allowlist, and host configuration rather than client input, so a model
  cannot compose its way to a table this application never meant to publish.
  Named explicitly because `Accounts.User` and `Legacy.User` collide on their
  short name, and "user" versus "legacy_user" is a distinction a model can act on.
  """
  @spec dynamic_allowlist() :: %{String.t() => module()}
  def dynamic_allowlist do
    AshA2ui.Dynamic.allowlist(%{
      "user" => AshEnterprise.Accounts.User,
      "team" => AshEnterprise.Accounts.Team,
      "business_unit" => AshEnterprise.Accounts.BusinessUnit,
      "role" => AshEnterprise.Security.Role,
      "legacy_user" => AshEnterprise.Legacy.User
    })
  end
end
