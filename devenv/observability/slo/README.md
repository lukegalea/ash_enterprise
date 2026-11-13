# Default SLO for SigNoz

This application's default service level objectives, as SigNoz alert rules and a dashboard. Provision them beside the module's own with the `observability.provision` option:

```nix
observability.provision = [ "${ash_enterprise}/devenv/observability/slo" ];
```

| Objective | Measured by | Default |
|---|---|---|
| Availability | `/health` probes answered 2xx, out of all `/health` probes (server spans with `url.path = '/health'`) | 99.5% over 30 days |
| Latency | p95 of `ash.action.duration` (`AshEnterprise.Telemetry.Metrics`) | under 500 ms |

Both numbers are **unmeasured defaults**: nothing here has been run against them for 30 days. They are where an owner starts, not a promise. A deployment that promises its customers uptime sets its own numbers, and the promise is the owner's.

| Rule | Fires when | Severity |
|---|---|---|
| SLO /health availability: error budget burning fast | more than 7.2% of `/health` probes failed over 1 hour (14.4 times the 0.5% budget) | critical |
| SLO /health availability: error budget burning slowly | more than 3% failed over 6 hours (6 times the budget) | warning |
| SLO /health: no probes answered for 10 minutes | no `/health` request answered for ten minutes: the application is down, or nothing probes it | critical |
| SLO Ash action p95 latency above 500 ms | p95 Ash action duration above 500 ms throughout 15 minutes | warning |

The two burn rates are the multiwindow pair from Google's SRE workbook ("Alerting on SLOs"): fast enough to page for an outage, slow enough not to page for a blip.

The SLI is measured where the application answers, so it cannot see a node that answers nothing. That is what the absent-probes rule is for, and why something outside the application must probe `/health`: the load balancer's health check or an uptime prober, every 30 to 60 seconds. That prober is the owner's; this repository ships none. `/health` is `AshEnterpriseWeb.Plugs.Health`: no sign-in, no data, 200 when the database and the job runner answer, 503 otherwise.

Each rule carries `category: availability` or `category: latency`. Like the module's own rules they route through SigNoz's notification policies and notify nobody until a channel and a policy are set up. An alert that reaches the application is recorded as an `alert.firing` occurrence in an organization, which opens an incident there (a duplicate joins the open one), and the `incident_triage` pack gives the tenant's On-call role a triage task (`docs/runbooks/incident-response.md`). A webhook channel delivers there through the application's alert webhook (`POST /webhooks/alerts-signoz`, `AshEnterprise.Automation.AlertWebhook`), behind a relay that holds the key and signs each delivery.

`test/ash_enterprise_web/health_test.exs` checks that every rule here filters on a path the application serves and a metric it reports.
