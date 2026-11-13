# Security alert rules for SigNoz

This application's own SigNoz alert rules, for the same signals as the `security_alerts` recipe pack (`priv/packs/security_alerts/`). Provision them beside the module's own with the `observability.provision` option:

```nix
observability.provision = [ "${ash_enterprise}/devenv/observability/security" ];
```

| Rule | Fires when | Severity |
|---|---|---|
| Refused sign-ins above 20 in 5 minutes | more than 20 `accounts:user.sign_in_with_password` spans refused (`ash.error.class = 'forbidden'`) in five minutes | warning |
| A role was assigned | any successful `security:user_role.assign` or `assign_governed` span | info |
| An API key was issued | any successful `accounts:api_key.issue` span | info |
| A break-glass session was approved | any successful `security:break_glass_session.approve` span | warning |

They count spans across the whole deployment, not per tenant: SigNoz holds no tenant boundary, so these are the deployment operator's alarms. A tenant's own alarms are the pack's recipes, which open a review in that tenant (`docs/QUESTIONS.md`, q38). The refused sign-in rule also counts refusals for addresses that belong to no account, which no tenant records.

Each rule carries `category: security`. Like the module's own rules they route through SigNoz's notification policies and notify nobody until a channel and a policy are set up. A webhook channel pointed at this application's alert webhook (`POST /webhooks/alerts-signoz`, `AshEnterprise.Automation.AlertWebhook`) records each firing alert as an `alert.firing` occurrence in the organization its key maps to, where the pack's `security_alerts.inbound_security_alert` recipe opens a review. SigNoz does not sign webhook bodies, so the channel delivers through a relay that holds the key and adds the `x-alert-key`, `x-alert-timestamp` and `x-alert-signature` headers.

`test/ash_enterprise/bpmn/alert_review_test.exs` checks that every span these rules name is one the application emits.
