defmodule AshEnterprise.Surfaces do
  @moduledoc """
  The surface registry: every screen this application serves, declared once.

  Everything that needs to know "what surfaces exist" derives from the list
  below rather than keeping its own copy:

    * the thin pages and their routes: an entry that names a `ui` and no
      `live` gets a generated `AshA2ui.LiveRenderer`
      (`AshEnterpriseWeb.SurfaceLive`) routed at its `path` (`generated/0`);
      hand-written renderers are declared `renderer: :specialist`;
    * the web nav (grouped menus) and the `/app` launcher, with its views by
      `audience` (`for_audience/2`) and its lookup of a record by a business
      reference or a run id over each entry's `searchable` attributes
      (`AshEnterprise.Surfaces.Search`);
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

  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Agents.{Console, MorningBrief}
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces.{Doors, Surface}
  alias AshEnterpriseWeb.A2ui
  alias AshEnterpriseWeb.A2uiLive
  alias AshEnterpriseWeb.DailyLive

  @groups [
    %{
      key: :day,
      label: dgettext_noop("default", "My day"),
      menu: :day,
      blurb:
        dgettext_noop("default", "Your calendar, mail, people and the approvals waiting on you.")
    },
    %{
      key: :operator,
      label: dgettext_noop("default", "Operator"),
      menu: :day,
      blurb:
        dgettext_noop(
          "default",
          "Linked accounts, their syncs, erasure, lineage and the audit trail."
        )
    },
    %{
      key: :processes,
      label: dgettext_noop("default", "Processes"),
      menu: :work,
      blurb:
        dgettext_noop(
          "default",
          "The processes this tenant runs, the decisions they consult, and what starts them."
        )
    },
    %{
      key: :judgments,
      label: dgettext_noop("default", "Judgments"),
      menu: :work,
      blurb:
        dgettext_noop(
          "default",
          "What the judgment loop leaves for a person: verdicts, band tables to certify, and what calibration earned."
        )
    },
    # Agent quality (AGT-60).
    %{
      key: :quality,
      label: dgettext_noop("default", "Agent quality"),
      menu: :work,
      blurb:
        dgettext_noop(
          "default",
          "How agent versions did on the same evaluation cases, with safety kept apart from quality."
        )
    },
    %{
      key: :compliance,
      label: dgettext_noop("default", "Compliance"),
      menu: :work,
      blurb:
        dgettext_noop(
          "default",
          "Findings, the evaluations behind them, and the rules they are judged against."
        )
    },
    %{
      key: :credentialing,
      label: dgettext_noop("default", "Credentialing"),
      menu: :work,
      blurb:
        dgettext_noop(
          "default",
          "A synthetic clinic activating its clinicians' credentials through governed requests, an agent reading their licence documents, and the tour over it."
        )
    },
    %{
      key: :org,
      label: dgettext_noop("default", "Organization"),
      menu: :org,
      blurb:
        dgettext_noop(
          "default",
          "Who can sign in, the teams and units they belong to, and their roles."
        )
    },
    %{
      key: :data,
      label: dgettext_noop("default", "Projections"),
      menu: :data,
      blurb: dgettext_noop("default", "Tables this application owns, projected from elsewhere.")
    },
    %{
      key: :mdm,
      label: dgettext_noop("default", "Master data"),
      menu: :data,
      blurb:
        dgettext_noop(
          "default",
          "Customer files imported, matched into golden records, and the matches a person decides."
        )
    },
    %{
      key: :legacy,
      label: dgettext_noop("default", "Legacy"),
      menu: :data,
      blurb: dgettext_noop("default", "The old system, read live through compatibility views.")
    }
  ]

  @menus [
    day: dgettext_noop("default", "My day"),
    work: dgettext_noop("default", "Work"),
    org: dgettext_noop("default", "Organization"),
    data: dgettext_noop("default", "Data")
  ]

  @surfaces [
    # --- My day -------------------------------------------------------------
    %Surface{
      key: :today,
      audience: [:member],
      label: dgettext_noop("default", "Today"),
      blurb: dgettext_noop("default", "Your morning brief, today's agenda and the day's pulse."),
      group: :day,
      order: 0,
      icon: "hero-sun",
      path: "/app/today",
      live: DailyLive.Today,
      renderer: :specialist,
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
      audience: [:member],
      label: dgettext_noop("default", "Agent"),
      blurb:
        dgettext_noop(
          "default",
          "Ask about your calendar, mail, Slack, people and approvals. Answers cite the records they came from; the model runs in the zone."
        ),
      group: :day,
      order: 5,
      icon: "hero-sparkles",
      path: "/app/agent",
      live: AshEnterpriseWeb.AssistantLive,
      resource: AshEnterprise.Assistant.Thread
    },
    %Surface{
      key: :calendar,
      audience: [:member],
      label: dgettext_noop("default", "Calendar"),
      blurb:
        dgettext_noop(
          "default",
          "Your events on a month or week grid, with today, tomorrow, this week and the next two weeks as quick ranges."
        ),
      group: :day,
      order: 10,
      icon: "hero-calendar-days",
      path: "/app/calendar",
      live: DailyLive.Calendar,
      renderer: :specialist,
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
      audience: [:member],
      label: dgettext_noop("default", "Inbox"),
      blurb: dgettext_noop("default", "Gmail threads, newest first."),
      group: :day,
      order: 20,
      icon: "hero-envelope",
      path: "/app/inbox",
      live: DailyLive.Inbox,
      renderer: :specialist,
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
      audience: [:member],
      label: dgettext_noop("default", "Slack"),
      blurb: dgettext_noop("default", "Slack channels, group DMs and DMs, newest first."),
      group: :day,
      order: 30,
      icon: "hero-chat-bubble-left-right",
      path: "/app/slack",
      live: DailyLive.Slack,
      renderer: :specialist,
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
      audience: [:member],
      label: dgettext_noop("default", "People"),
      blurb: dgettext_noop("default", "Everyone you correspond and meet with, and their events."),
      group: :day,
      order: 40,
      icon: "hero-user-circle",
      path: "/app/people",
      live: DailyLive.People,
      renderer: :specialist,
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
      audience: [:member],
      label: dgettext_noop("default", "Action items"),
      blurb:
        dgettext_noop(
          "default",
          "Everything you have to do: captured items in Inbox, Today, Later and Done, with the process tasks waiting on you beside them."
        ),
      group: :day,
      order: 45,
      icon: "hero-check-circle",
      path: "/app/action-items",
      live: DailyLive.ActionItems,
      renderer: :specialist,
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
      audience: [:member, :reviewer],
      label: dgettext_noop("default", "Approvals"),
      blurb: dgettext_noop("default", "The tasks waiting on your decision."),
      group: :day,
      order: 50,
      icon: "hero-check-badge",
      path: "/app/approvals",
      live: DailyLive.Approvals,
      renderer: :specialist,
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
      audience: [:member, :operator],
      label: dgettext_noop("default", "Accounts & syncs"),
      blurb: dgettext_noop("default", "Your linked accounts and how their syncs are doing."),
      group: :operator,
      order: 0,
      icon: "hero-arrow-path",
      path: "/app/accounts",
      live: DailyLive.Accounts,
      renderer: :specialist,
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
      audience: [:operator],
      label: dgettext_noop("default", "Erasure scopes"),
      blurb:
        dgettext_noop("default", "Erasure scopes and the irreversible, typed-confirmation shred."),
      group: :operator,
      order: 10,
      icon: "hero-trash",
      path: "/app/erasure",
      live: DailyLive.Erasure,
      renderer: :specialist,
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
      audience: [:operator],
      searchable: [:id],
      label: dgettext_noop("default", "Lineage"),
      blurb:
        dgettext_noop(
          "default",
          "What ran, what it read and wrote, and what failed, drawn as a live graph."
        ),
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
      renderer: :specialist,
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
      key: :recovery,
      audience: [:operator],
      label: dgettext_noop("default", "Recovery"),
      blurb:
        dgettext_noop(
          "default",
          "Settle an uncertain outcome, simulate or rerun a request, or cancel one, saying why."
        ),
      description:
        "Recovery for governed invocations: the uncertain outcomes waiting for a person, " <>
          "and for any invocation the acts its status allows (settle, simulate, rerun, " <>
          "cancel), each stating what it does and recorded with who did it and why.",
      group: :operator,
      order: 25,
      icon: "hero-lifebuoy",
      path: "/app/recovery",
      live: AshEnterpriseWeb.RecoveryLive,
      resource: AshEnterprise.Execution.Invocation
    },
    # The model-profile surface (AGT-64): what each model profile may be used for,
    # whether it is known to answer, and what it is restricted from.
    %Surface{
      key: :model_profiles,
      audience: [:operator],
      label: dgettext_noop("default", "Model profiles"),
      blurb:
        dgettext_noop(
          "default",
          "Which model each profile runs, what it may be used for, whether it is known to answer, and what it is restricted from."
        ),
      group: :operator,
      order: 27,
      icon: "hero-cpu-chip",
      path: "/app/models",
      live: AshEnterpriseWeb.ModelProfilesLive,
      resource: AshEnterprise.AI.ModelProfile
    },
    %Surface{
      key: :audit,
      audience: [:operator, :reviewer],
      label: dgettext_noop("default", "Audit trail"),
      blurb:
        dgettext_noop(
          "default",
          "Every recorded change, newest first, each linked to the run that made it."
        ),
      group: :operator,
      order: 30,
      icon: "hero-clipboard-document-list",
      path: "/app/audit",
      live: AshEnterpriseWeb.AuditLive,
      renderer: :specialist,
      ui: A2ui.AuditUI,
      resource: AshEnterprise.Audit.EventLog,
      context: :entry,
      door: :audit,
      acp: %{command: "audit trail", aliases: ["audit"]}
    },
    # One piece of work on one timeline, read as the viewer (AGT-50). Its door is open:
    # the trace shows only what the person may read, so a closed door would explain
    # nothing the trace does not.
    %Surface{
      key: :explorer,
      audience: [:operator, :reviewer],
      label: dgettext_noop("default", "Execution explorer"),
      blurb:
        dgettext_noop(
          "default",
          "One piece of work, followed through its process, runs, decisions, approvals and calls, on one timeline."
        ),
      group: :operator,
      order: 40,
      icon: "hero-queue-list",
      path: "/app/explorer",
      live: AshEnterpriseWeb.ExplorerLive,
      resource: AshEnterprise.Execution.Entry
    },

    # --- Processes ----------------------------------------------------------
    %Surface{
      key: :tasks,
      audience: [:member, :reviewer],
      label: dgettext_noop("default", "My tasks"),
      blurb:
        dgettext_noop(
          "default",
          "Every process task routed to you: claim it, complete it, or hand it on."
        ),
      group: :processes,
      order: 0,
      icon: "hero-inbox-stack",
      path: "/app/tasks",
      ui: A2ui.TaskBoardUI,
      resource: HumanTask,
      context: :task,
      acp: %{command: "my tasks"}
    },
    # Stalled reviews (AGT-61): the view the assistant's `stalled_reviews` tool puts
    # in an answer, reached without chat. No `context`: tasks open in detail on
    # Approvals and My tasks, never here.
    %Surface{
      key: :stalled_reviews,
      audience: [:reviewer, :operator],
      label: dgettext_noop("default", "Stalled reviews"),
      blurb:
        dgettext_noop(
          "default",
          "Reviews and other process tasks you can see that have waited more than two days."
        ),
      group: :processes,
      order: 2,
      icon: "hero-clock",
      path: "/app/reviews/stalled",
      ui: A2ui.StalledReviewsUI,
      resource: HumanTask,
      acp: %{command: "stalled reviews"}
    },
    # The flight views (PROD-10): a process drawn with a marker on every step a
    # run is standing on. `:flight` is the first surface over Instance with a
    # detail, so every link to a run (`link :instance`, `link :process_run`)
    # opens there; the two process views list every run of one process.
    %Surface{
      key: :flight,
      audience: [:operator, :reviewer],
      searchable: [:id],
      label: dgettext_noop("default", "Flight view"),
      blurb:
        dgettext_noop(
          "default",
          "One process run on its diagram, with a marker on the step it is on now."
        ),
      group: :processes,
      order: 5,
      icon: "hero-map",
      path: "/app/flights",
      live: AshEnterpriseWeb.FlightLive.Instance,
      renderer: :specialist,
      ui: A2ui.FlightUI,
      resource: AshEnterprise.Bpmn.Instance,
      context: :instance,
      acp: %{command: "flight", aliases: ["flight view"]}
    },
    %Surface{
      key: :brief_flight,
      audience: [:operator],
      label: dgettext_noop("default", "Brief approvals in flight"),
      blurb: dgettext_noop("default", "Every running morning brief, on the step it is on now."),
      group: :processes,
      order: 6,
      icon: "hero-sun",
      path: "/app/flights/briefs",
      live: AshEnterpriseWeb.FlightLive.Briefs,
      renderer: :specialist,
      ui: A2ui.BriefFlightUI,
      resource: AshEnterprise.Bpmn.Instance,
      acp: %{command: "brief flight", aliases: ["briefs in flight"]}
    },
    %Surface{
      key: :steward_flight,
      audience: [:operator],
      label: dgettext_noop("default", "Stewardship in flight"),
      blurb:
        dgettext_noop("default", "Every match under steward review, on the step it is on now."),
      group: :processes,
      order: 7,
      icon: "hero-hand-raised",
      path: "/app/flights/stewardship",
      live: AshEnterpriseWeb.FlightLive.Stewardship,
      renderer: :specialist,
      ui: A2ui.StewardFlightUI,
      resource: AshEnterprise.Bpmn.Instance,
      acp: %{command: "stewardship flight", aliases: ["steward flight"]}
    },
    %Surface{
      key: :processes,
      audience: [:builder],
      label: dgettext_noop("default", "Processes"),
      blurb:
        dgettext_noop(
          "default",
          "Every BPMN process this tenant can run: baselines and its own customizations."
        ),
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
      audience: [:builder],
      label: dgettext_noop("default", "Decisions"),
      blurb:
        dgettext_noop(
          "default",
          "The DMN decisions processes route on, resolved when they are asked."
        ),
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
      audience: [:builder],
      label: dgettext_noop("default", "Triggers"),
      blurb:
        dgettext_noop(
          "default",
          "What starts a process: a watched write, a guard, and what it starts."
        ),
      group: :processes,
      order: 30,
      icon: "hero-bolt",
      path: "/app/triggers",
      live: AshEnterpriseWeb.Bpmn.CatalogLive,
      live_action: :triggers,
      resource: AshEnterprise.Bpmn.Subscription,
      acp: %{command: "triggers"}
    },

    # The artifact registry's pages (AshEnterprise.Artifacts): every versioned thing,
    # its header, validation and semantic diff. Removable with AshEnterpriseWeb.ArtifactLive,
    # its live_session and this entry.
    %Surface{
      key: :artifacts,
      audience: [:builder, :reviewer],
      label: dgettext_noop("default", "Artifacts"),
      blurb:
        dgettext_noop(
          "default",
          "Every version of what is authored here, what it references, whether it checks out and what changed."
        ),
      group: :processes,
      order: 40,
      icon: "hero-document-duplicate",
      path: "/app/artifacts",
      live: AshEnterpriseWeb.ArtifactLive
    },

    # --- Compliance (ADR 0035) -----------------------------------------------
    %Surface{
      key: :findings,
      audience: [:reviewer],
      label: dgettext_noop("default", "Findings"),
      blurb: dgettext_noop("default", "Who is breaching which control, and why."),
      group: :compliance,
      order: 0,
      icon: "hero-shield-exclamation",
      path: "/app/compliance/findings",
      ui: A2ui.FindingUI,
      resource: AshCompliance.Resources.Finding,
      door: :compliance,
      acp: %{command: "findings"}
    },
    %Surface{
      key: :evaluations,
      audience: [:reviewer],
      label: dgettext_noop("default", "Evaluations"),
      blurb:
        dgettext_noop(
          "default",
          "The append-only log of what the engine decided, and on what facts."
        ),
      group: :compliance,
      order: 10,
      icon: "hero-clipboard-document-check",
      path: "/app/compliance/evaluations",
      ui: A2ui.ComplianceEvaluationUI,
      resource: AshCompliance.Resources.ComplianceEvaluation,
      door: :compliance,
      acp: %{command: "evaluations"}
    },
    %Surface{
      key: :rule_sets,
      audience: [:builder],
      label: dgettext_noop("default", "Rule sets"),
      blurb:
        dgettext_noop("default", "Rule set revisions: their layer, lifecycle and content hash."),
      group: :compliance,
      order: 20,
      icon: "hero-scale",
      path: "/app/compliance/rule-sets",
      ui: A2ui.RuleSetRevisionUI,
      resource: AshCompliance.Resources.RuleSetRevision,
      door: :compliance,
      acp: %{command: "rule sets"}
    },
    %Surface{
      key: :bundles,
      audience: [:builder],
      label: dgettext_noop("default", "Policy bundles"),
      blurb:
        dgettext_noop("default", "Compiled bundles: which is active for whom, and since when."),
      group: :compliance,
      order: 30,
      icon: "hero-archive-box",
      path: "/app/compliance/bundles",
      ui: A2ui.PolicyBundleUI,
      resource: AshCompliance.Resources.PolicyBundle,
      door: :compliance,
      acp: %{command: "bundles", aliases: ["policy bundles"]}
    },
    %Surface{
      key: :catalogs,
      audience: [:builder],
      label: dgettext_noop("default", "Catalogs"),
      blurb:
        dgettext_noop("default", "Compliance catalogs, and the OSCAL documents they came from."),
      group: :compliance,
      order: 40,
      icon: "hero-book-open",
      path: "/app/compliance/catalogs",
      ui: A2ui.CatalogUI,
      resource: AshCompliance.Resources.Catalog,
      context: :catalog,
      door: :compliance,
      acp: %{command: "catalogs"}
    },
    %Surface{
      key: :profiles,
      audience: [:builder],
      label: dgettext_noop("default", "Profiles"),
      blurb:
        dgettext_noop("default", "Tailoring profiles: who tailored what, against which catalog."),
      group: :compliance,
      order: 50,
      icon: "hero-adjustments-horizontal",
      path: "/app/compliance/profiles",
      ui: A2ui.ProfileUI,
      resource: AshCompliance.Resources.Profile,
      door: :compliance,
      acp: %{command: "profiles"}
    },

    # --- Organization ------------------------------------------------------------
    %Surface{
      key: :users,
      audience: [:operator],
      label: dgettext_noop("default", "Users"),
      blurb: dgettext_noop("default", "People with accounts in this application."),
      description:
        "People with accounts in this application, with their status and sign-up date.",
      group: :org,
      order: 0,
      icon: "hero-users",
      path: "/app/users",
      ui: A2ui.UserUI,
      resource: AshEnterprise.Accounts.User,
      context: :user,
      acp: %{command: "users"}
    },
    %Surface{
      key: :teams,
      audience: [:operator],
      label: dgettext_noop("default", "Teams"),
      blurb: dgettext_noop("default", "Teams, which own records alongside users."),
      description: "Teams, which own records alongside users in the polymorphic ownership model.",
      group: :org,
      order: 10,
      icon: "hero-user-group",
      path: "/app/teams",
      ui: A2ui.TeamUI,
      resource: AshEnterprise.Accounts.Team,
      context: :team,
      acp: %{command: "teams"}
    },
    %Surface{
      key: :roles,
      audience: [:operator],
      label: dgettext_noop("default", "Roles"),
      blurb: dgettext_noop("default", "Named bundles of privileges a user can hold."),
      description: "Security roles, which are the named bundles of privileges a user can hold.",
      group: :org,
      order: 20,
      icon: "hero-key",
      path: "/app/roles",
      ui: A2ui.RoleUI,
      resource: AshEnterprise.Security.Role,
      acp: %{command: "roles"}
    },
    %Surface{
      key: :business_units,
      audience: [:operator],
      label: dgettext_noop("default", "Business units"),
      blurb: dgettext_noop("default", "The hierarchy that authorization depth expands over."),
      description: "The business-unit hierarchy that authorization depth expands over.",
      group: :org,
      order: 30,
      icon: "hero-building-office-2",
      path: "/app/business-units",
      ui: A2ui.BusinessUnitUI,
      resource: AshEnterprise.Accounts.BusinessUnit,
      context: :business_unit,
      acp: %{command: "business units"}
    },

    # --- Projections -----------------------------------------------------------
    %Surface{
      key: :directory,
      audience: [:member],
      label: dgettext_noop("default", "Directory"),
      blurb:
        dgettext_noop(
          "default",
          "The legacy estate's people, projected into a table this application owns."
        ),
      group: :data,
      order: 0,
      icon: "hero-identification",
      path: "/app/directory",
      live: A2uiLive.ProjectedUsers,
      renderer: :specialist,
      ui: A2ui.ProjectedUserUI,
      resource: AshEnterprise.Accounts.ProjectedUser,
      acp: %{command: "directory"}
    },

    # --- Master data (ADR 0054) -------------------------------------------------
    # The steward's verdict is a person's act: the candidate's :confirm,
    # :reject and :escalate actions refuse system and AI actors by policy, so
    # the queue opens to any signed-in person and the policies decide what
    # they may read and act on.
    # The judgment surfaces (ADR 0061): ash_judgments' surfaces bound to this
    # application's resources. The acts are person-gated by policy, not by a
    # door.
    # --- Agent quality (AGT-60) -------------------------------------------------
    %Surface{
      key: :comparison,
      audience: [:builder, :reviewer],
      label: dgettext_noop("default", "Compare candidates"),
      blurb:
        dgettext_noop(
          "default",
          "Evaluation runs side by side, case by case, with safety in a lane of its own."
        ),
      description:
        "Candidates compared on the same evaluation cases (ADR 0058): each suite run of " <>
          "a suite as a column, each case improved, degraded, failed, skipped or not " <>
          "measured against a baseline, and guardrail and policy outcomes kept apart " <>
          "from the quality aggregate. A candidate whose safety failed or was not " <>
          "measured is never recommended.",
      group: :quality,
      order: 10,
      icon: "hero-view-columns",
      path: "/app/quality/compare",
      live: AshEnterpriseWeb.ComparisonLive,
      resource: AshEnterprise.Quality.SuiteRun
    },
    %Surface{
      key: :judgment_verdicts,
      audience: [:reviewer],
      label: dgettext_noop("default", "Verdicts"),
      blurb:
        dgettext_noop(
          "default",
          "Judgments the band table sent to review, awaiting your verdict."
        ),
      group: :judgments,
      order: 0,
      icon: "hero-scale",
      path: "/app/judgments",
      ui: A2ui.Judgments.VerdictsUI,
      resource: AshEnterprise.SystemOne.Banding,
      acp: %{command: "verdicts", aliases: ["judgments awaiting verdict"]}
    },
    %Surface{
      key: :judgment_band_tables,
      audience: [:reviewer],
      label: dgettext_noop("default", "Band tables to certify"),
      blurb:
        dgettext_noop(
          "default",
          "Band tables a calibration run earned, awaiting a person's certification."
        ),
      group: :judgments,
      order: 1,
      icon: "hero-check-badge",
      path: "/app/judgments/band-tables",
      ui: A2ui.Judgments.BandTablesUI,
      resource: AshEnterprise.SystemOne.CalibrationRun,
      acp: %{command: "band tables", aliases: ["certify band tables"]}
    },
    %Surface{
      key: :judgment_certifications,
      audience: [:reviewer],
      label: dgettext_noop("default", "Certified band tables"),
      blurb: dgettext_noop("default", "The band tables in force, with who certified them."),
      group: :judgments,
      order: 2,
      icon: "hero-shield-check",
      path: "/app/judgments/certifications",
      ui: A2ui.Judgments.CertificationsUI,
      resource: AshEnterprise.SystemOne.BandTableCertification,
      acp: %{command: "certified band tables", aliases: ["certifications"]}
    },
    %Surface{
      key: :judgment_calibration,
      audience: [:builder],
      label: dgettext_noop("default", "Calibration"),
      blurb:
        dgettext_noop(
          "default",
          "Every calibration run: what it measured and the threshold it earned."
        ),
      group: :judgments,
      order: 3,
      icon: "hero-chart-bar",
      path: "/app/judgments/calibration",
      ui: A2ui.Judgments.CalibrationUI,
      resource: AshEnterprise.SystemOne.CalibrationRun,
      acp: %{command: "calibration", aliases: ["calibration runs"]}
    },
    %Surface{
      key: :judgment_facts,
      audience: [:reviewer],
      label: dgettext_noop("default", "Facts"),
      blurb:
        dgettext_noop(
          "default",
          "The facts current now, per subject, with the admission behind each."
        ),
      group: :judgments,
      order: 4,
      icon: "hero-document-check",
      path: "/app/judgments/facts",
      ui: A2ui.Judgments.FactsUI,
      resource: AshEnterprise.SystemOne.Fact,
      acp: %{command: "facts", aliases: ["judged facts"]}
    },
    %Surface{
      key: :steward,
      audience: [:reviewer],
      label: dgettext_noop("default", "Steward queue"),
      blurb:
        dgettext_noop(
          "default",
          "Review-banded matches awaiting a person's confirm, reject or unsure."
        ),
      group: :mdm,
      order: 0,
      icon: "hero-hand-raised",
      path: "/app/mdm",
      ui: A2ui.MdmStewardUI,
      resource: AshEnterprise.Mdm.MatchCandidate,
      context: :candidate,
      acp: %{command: "steward queue", aliases: ["steward"]}
    },
    %Surface{
      key: :mdm_import,
      audience: [:operator],
      label: dgettext_noop("default", "Import CSV"),
      blurb:
        dgettext_noop(
          "default",
          "Upload a customer file, map its columns onto the golden record, run the import."
        ),
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
      audience: [:member],
      label: dgettext_noop("default", "Golden records"),
      blurb: dgettext_noop("default", "The merged view of the customer, with merge lineage."),
      description:
        "Golden records (canonical people) built by the MDM pipeline, with each row's " <>
          "merge lineage readable: who absorbed whom, pointing at whom.",
      group: :mdm,
      order: 20,
      icon: "hero-star",
      path: "/app/mdm/golden",
      live: A2uiLive.MdmGolden,
      renderer: :specialist,
      ui: A2ui.MdmGoldenUI,
      resource: AshEnterprise.Canonical.Person,
      # People is the first surface over Person, so a plain person link opens
      # there; links that name this surface (`{:mdm_golden, ...}`) open here.
      context: :person,
      acp: %{command: "golden records", aliases: ["goldens"]}
    },
    %Surface{
      key: :time_travel,
      audience: [:reviewer],
      label: dgettext_noop("default", "Time travel"),
      blurb:
        dgettext_noop(
          "default",
          "Who a person resolved to, and what was true about them, at any moment."
        ),
      group: :mdm,
      order: 25,
      icon: "hero-clock",
      path: "/app/time-travel",
      live: AshEnterpriseWeb.TimeTravelLive,
      resource: AshEnterprise.Mdm.SourceIdentity,
      acp: %{command: "time travel", aliases: ["as of", "history"]}
    },
    %Surface{
      key: :mdm_mappings,
      audience: [:builder],
      label: dgettext_noop("default", "MDM mappings"),
      blurb: dgettext_noop("default", "The mapping version chain: no-deploy onboarding."),
      description:
        "Versioned schema mappings (ADR 0054): draft → validate → activate, one per " <>
          "customer schema. Activation supersedes; nothing is overwritten.",
      group: :mdm,
      order: 30,
      icon: "hero-arrows-right-left",
      path: "/app/mdm/mappings",
      ui: A2ui.MdmMappingUI,
      resource: AshEnterprise.Mdm.Mapping,
      context: :mapping,
      acp: %{command: "mdm mappings", aliases: ["mappings"]}
    },
    %Surface{
      key: :mdm_batches,
      audience: [:operator],
      label: dgettext_noop("default", "Import batches"),
      blurb:
        dgettext_noop("default", "Every import by status, with its counts and its staged rows."),
      description:
        "MDM import batches (ADR 0054) as a board by status — open, staging, matching, " <>
          "review, closed, failed — each with its counters, failure reason, pinned mapping " <>
          "and staged rows.",
      group: :mdm,
      order: 40,
      icon: "hero-rectangle-stack",
      path: "/app/mdm/batches",
      ui: A2ui.MdmBatchUI,
      resource: AshEnterprise.Mdm.ImportBatch,
      context: :batch,
      acp: %{command: "import batches", aliases: ["batches"]}
    },

    # --- Credentialing -----------------------------------------------------------
    %Surface{
      key: :credentials,
      audience: [:member, :reviewer],
      searchable: [:number, :registry_reference],
      label: dgettext_noop("default", "Credentials"),
      blurb:
        dgettext_noop(
          "default",
          "The clinic's credentials: ask to activate one, and see what the registry holds."
        ),
      description:
        "The synthetic clinic's clinician credentials (licences and certifications), each " <>
          "pending or active with the registry. Activating one is a governed request that " <>
          "a credentialing committee member other than the requester approves. A credential " <>
          "shows what the licence reader found in its documents, with the lines it cites.",
      group: :credentialing,
      order: 0,
      icon: "hero-identification",
      path: "/app/credentialing",
      ui: A2ui.CredentialUI,
      resource: AshEnterprise.Credentialing.Credential,
      context: :credential,
      acp: %{command: "credentials"}
    },
    %Surface{
      key: :credentialing_tour,
      audience: [:member, :builder],
      label: dgettext_noop("default", "Credentialing tour"),
      blurb:
        dgettext_noop(
          "default",
          "A guided tour of governed activation: ask, approve, and what happens when the world changes in between."
        ),
      group: :credentialing,
      order: 10,
      icon: "hero-map",
      path: "/app/showcase/credentialing",
      live: AshEnterpriseWeb.ShowcaseLive.Credentialing,
      resource: AshEnterprise.Credentialing.Credential,
      acp: %{command: "credentialing tour", aliases: ["tour"]}
    },

    # --- Legacy ------------------------------------------------------------------
    %Surface{
      key: :legacy_users,
      audience: [:member],
      label: dgettext_noop("default", "Legacy users"),
      blurb:
        dgettext_noop(
          "default",
          "The old system's people, read live through a compatibility view."
        ),
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
      renderer: :specialist,
      ui: A2ui.LegacyUserUI,
      resource: AshEnterprise.Legacy.User,
      acp: %{command: "legacy users"}
    }
  ]

  @audiences [
    member: dgettext_noop("default", "Members"),
    reviewer: dgettext_noop("default", "Reviewers"),
    builder: dgettext_noop("default", "Builders"),
    operator: dgettext_noop("default", "Operators")
  ]

  # Every surface says who it is for, from the closed set.
  for %Surface{key: key, audience: audience} <- @surfaces,
      audience == [] or not Enum.all?(audience, &Keyword.has_key?(@audiences, &1)) do
    raise ArgumentError,
          "surface #{inspect(key)} has audience #{inspect(audience)}; " <>
            "declare one or more of #{inspect(Keyword.keys(@audiences))}"
  end

  # A thin surface names its UI and no LiveView: the registry names the page
  # it gets, which AshEnterpriseWeb.SurfaceLive defines and the router routes.
  @surfaces Enum.map(@surfaces, fn
              %Surface{live: nil, ui: nil, key: key} ->
                raise ArgumentError,
                      "surface #{inspect(key)} names neither a LiveView nor a UI to generate one from"

              %Surface{live: nil, key: key} = surface ->
                live = Module.concat(AshEnterpriseWeb.SurfaceLive, Macro.camelize("#{key}"))
                %{surface | live: live, renderer: :generated}

              surface ->
                surface
            end)

  @group_rank @groups |> Enum.with_index() |> Map.new(fn {g, i} -> {g.key, i} end)
  @sorted Enum.sort_by(@surfaces, &{Map.fetch!(@group_rank, &1.group), &1.order})
  @by_key Map.new(@sorted, &{&1.key, &1})

  # -- reading the registry ---------------------------------------------------

  @doc "Every surface, in group order then `order`."
  @spec all() :: [Surface.t()]
  def all, do: @sorted

  @doc """
  The surfaces whose page is generated from the entry
  (`AshEnterpriseWeb.SurfaceLive` defines it, the router routes it).
  """
  @spec generated() :: [Surface.t()]
  def generated, do: Enum.filter(@sorted, &(&1.renderer == :generated))

  @doc """
  A registry label or blurb in the current process's Gettext locale. The texts
  are marked for extraction where they are declared (`dgettext_noop/2`), so
  they sit in the `default` domain; one with no translation reads as written.
  The ambient locale is the rendering convenience `PutLocale` and `LiveLocale`
  set; it is not read where a surface leaves the request (ACP).
  """
  @spec translate(String.t()) :: String.t()
  def translate(text), do: Gettext.dgettext(AshEnterpriseWeb.Gettext, "default", text)

  @doc """
  The audiences a surface can be for, in the launcher's order, with their
  labels (marked for extraction, translate with `translate/1`).
  """
  @spec audiences() :: keyword(String.t())
  def audiences, do: @audiences

  @doc """
  The audience a launcher was asked for (`"reviewer"`), or `nil` for
  everyone: an unknown or missing name is `nil`, never a new atom.
  """
  @spec audience(String.t() | nil) :: Surface.audience() | nil
  def audience(name) when is_binary(name),
    do: Enum.find_value(@audiences, fn {key, _label} -> Atom.to_string(key) == name && key end)

  def audience(_name), do: nil

  @doc "The `surfaces` for `audience`; `nil` keeps them all."
  @spec for_audience([Surface.t()], Surface.audience() | nil) :: [Surface.t()]
  def for_audience(surfaces, nil), do: surfaces
  def for_audience(surfaces, audience), do: Enum.filter(surfaces, &(audience in &1.audience))

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
  a Gmail thread in the Inbox — falling back to the first. The record may be a map
  of only the fields `record_match` reads (`AshEnterprise.Canonical.Calculations.OriginRef`
  passes `%{external_system: source}`).
  """
  @spec record_surface(module(), map() | nil) :: Surface.t() | nil
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
  The surfaces `actor` may open: behind an open door, over a resource they
  may read (`readable?/2`). What every launcher offers — the web's `/app`
  and its ctrl+k picker (`AshEnterpriseWeb.Shell`) and ACP's
  `_ash/surfaces/list` (`AshEnterprise.Acp.ExtMethods`) — so neither lists
  a surface the other would refuse.
  """
  @spec openable(term()) :: [Surface.t()]
  def openable(actor), do: Enum.filter(visible(actor), &readable?(&1, actor))

  @doc """
  Whether `actor` may read `surface`'s resource at all (`Ash.can?` on its
  primary read). A filter policy answers yes without a query: this asks
  whether some row could be theirs, not which.
  """
  @spec readable?(Surface.t(), term()) :: boolean()
  def readable?(%Surface{resource: nil}, _actor), do: true

  def readable?(%Surface{resource: resource}, actor) do
    case Ash.Resource.Info.primary_action(resource, :read) do
      %{name: read} -> Ash.can?({resource, read}, actor, tenant: ActorContext.tenant(actor))
      nil -> false
    end
  rescue
    _error -> false
  end

  @doc """
  The groups with the surfaces `actor` may open, empty groups dropped:
  `[%{key, label, menu, blurb, surfaces: [Surface.t()]}]`. `surfaces` picks
  which: `visible/1` (doors only, what the nav lists) by default, or
  `openable/1`.
  """
  @spec grouped(term(), (term() -> [Surface.t()])) :: [map()]
  def grouped(actor, surfaces \\ &visible/1) do
    visible = surfaces.(actor)

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
