# Runbook: an alert at three in the morning

Written 2026-11-13. Code: `AshEnterpriseWeb.Plugs.Health` (`/health`), `devenv/observability/slo/` (the default SLO as
SigNoz rules and a dashboard), `AshEnterprise.Automation.Incident` and `AshEnterprise.Automation.Incidents` (alerts
become incidents), `priv/packs/incident_triage/` (the triage process and recipe). Tests:
`test/ash_enterprise_web/health_test.exs`, `test/ash_enterprise/bpmn/incident_triage_pack_test.exs`,
`test/ash_enterprise_web/incident_webhook_test.exs`.

This page says what the template does when something breaks and what it leaves to whoever runs it. The split is the
point: a template can make an alert into an assigned, audited task, but it cannot wake anyone.

## What the template does, and what is yours

| | The template | The owner |
|---|---|---|
| Is the node up? | `GET /health`: no sign-in, no data, 200 when the database answers and the job runner is running, 503 otherwise | Something outside the application that probes it every 30 to 60 seconds: the load balancer's health check or an uptime prober |
| What is promised | A default objective, written down: 99.5% of `/health` probes answered over 30 days, p95 Ash action latency under 500 ms. **Unmeasured**: nothing has run against it for 30 days | The number promised to customers, if any, the status page, and what a missed month costs |
| Noticing | SigNoz rules for the objective: fast and slow error-budget burn, no probes answered for 10 minutes, p95 latency | A SigNoz notification channel and policy. The rules notify nobody until one exists |
| Getting the alert into the application | The inbound alert webhook (`POST /webhooks/alerts-signoz`, `/webhooks/alerts-glitchtip`, q38) records a signed alert as an `alert.firing` occurrence in the key's organization, which opens an incident there; a duplicate joins the open one | `ALERT_WEBHOOK_KEYS`, and a relay that holds the key and signs each delivery: neither tool signs a webhook body |
| Telling a person | The `incident_triage` pack gives the tenant's **On-call** role one triage task per incident, on the task list | Who holds On-call (the rota), and a pager or phone call if the task list is not enough at 3 a.m. The task list does not wake anyone |
| Doing something | The person resolves the incident or escalates it to an administrator; the task, the run and every incident change are in the audit chain | Diagnosis, the fix, and what the customer is told |

## Setting it up

1. **Probe `/health`.** Point the load balancer's health check or an uptime prober at it. In production
   `/health` is excluded from the HTTPS redirect, so a plain-HTTP check works.
2. **Provision the SLO.** Add the directory to SigNoz with the observability module's option:
   `observability.provision = [ "${ash_enterprise}/devenv/observability/slo" ];`. Change the numbers in the JSON to
   your own objective before you promise anything.
3. **Make a channel.** In SigNoz, add a notification channel and a policy that routes `category: availability` and
   `category: latency` to it. To open incidents, point a webhook channel at the relay in front of
   `/webhooks/alerts-signoz`, with a key in `ALERT_WEBHOOK_KEYS` for the organization the incidents belong to.
4. **Name who is on call.** Every tenant seeded now has the starter **On-call** role, assigned to nobody. For tenants
   seeded before it existed: `mix ash_enterprise.platform.grant_on_call` (dry run), then `--apply`. Give the role to
   the people on the rota in the role admin. It reads incidents and nothing else.
5. **Install and publish the pack.** `mix ash_enterprise.packs.install incident_triage --tenant <tenant> --as <administrator's email>`
   installs drafts. Nothing runs until a person publishes the process `incident.triage` and then the recipe
   `incident.triage.opened`. The recipe is human tasks only: it opens tasks and runs nothing on its own.

## When an incident opens

- **One alert, one incident.** The key is the provider and the alerting rule. The same rule firing again while the
  incident is open adds to its `alert_count` and moves `last_alert_at`; it does not open a second incident or a
  second task. Another rule is another incident.
- **The task.** "Triage the incident" goes to every holder of On-call. One person claims it. `resolved` ends the run;
  `escalate` hands it to the tenant's administrators ("Take over the escalated incident").
- **First step.** Read the incident (title, severity, when it started, how many alerts since), then the traces: the
  SigNoz SLO dashboard and the traces around the incident's start, which carry the correlation id that joins a
  request to every write it made.

## When an incident closes

- Its alert resolves (an `alert.resolved` occurrence for the same key): closed as `alert_resolved`. A rule fires once
  per label set, and SigNoz sends each as its own alert (its fingerprint); the incident closes only when every series
  that fired has resolved, and until then the row lists the ones still firing (`firing_series`).
- Its triage finished: the next alert for the same key closes it as `triage_concluded` and opens a new incident with
  a new task. Until that next alert, the row still reads `open`; the triage run's status is what says it was handled.

## What this does not cover

- **A node that answers nothing.** `/health` is measured where the application answers. The absent-probes rule fires
  when no probe has been answered for 10 minutes, but only if SigNoz itself is up and something is probing.
- **Failures with no alert.** A job discarded or a crash shows in SigNoz (the module's Oban discard rule, error
  rate) and becomes an incident only through an alert rule delivered to the inbound webhook.
- **Security events.** A role grant, a break-glass approval or a refused sign-in is reviewed by the security alert
  recipes (q38), not here. A security-labelled alert that reaches the application also opens an incident.
- **The rota, the pager and customer commitments.** None of these is in the repository, and none can be.
