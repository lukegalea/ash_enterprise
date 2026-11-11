// Browser error reporting. See priv/js/package.json for the pinned @sentry/browser.
//
//   // A git dependency with `sparse: "telemetry"` keeps the directory name; a path
//   // dependency or a Hex package does not.
//   import {startBrowserErrors} from "../../deps/ash_enterprise_telemetry/telemetry/priv/js/sentry_browser.js"
//   startBrowserErrors({dsn: meta.content})
//
// Reports go to the same-origin tunnel, AshEnterprise.Telemetry.SentryTunnel, which is
// off until it is configured with this DSN.
//
// An event raised while a browser span is active is tagged with its trace_id and
// span_id, so a report joins its trace. otel_browser.js supplies the span.
//
// GlitchTip does not implement sessions, so the session integration is removed.
// Console breadcrumbs are off, because application logging is not meant for a third
// party, and every breadcrumb's text is capped (capBreadcrumb), so one huge URL cannot
// push an event past the tunnel's body limit. Tracing is not initialised: traces belong
// to the OTLP pipeline.

import * as Sentry from "@sentry/browser"

import {capBreadcrumb, traceTagsBeforeSend} from "./browser_error_tags.js"

// In the pinned SDK, console breadcrumbs come from their own Console integration, not
// from Breadcrumbs, so both are handled; capBreadcrumb drops any that still arrive.
const DROPPED_INTEGRATIONS = new Set(["BrowserSession", "Console"])

export const startBrowserErrors = ({dsn, tunnel = "/sentry/tunnel", environment, release} = {}) => {
  if (!dsn) return

  Sentry.init({
    dsn,
    tunnel,
    environment,
    release,
    tracesSampleRate: undefined,
    beforeSend: traceTagsBeforeSend,
    beforeBreadcrumb: capBreadcrumb,
    integrations: integrations =>
      integrations
        .filter(integration => !DROPPED_INTEGRATIONS.has(integration.name))
        .map(integration =>
          integration.name === "Breadcrumbs"
            ? Sentry.breadcrumbsIntegration({console: false})
            : integration
        )
  })
}
