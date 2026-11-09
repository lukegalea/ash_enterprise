// Browser error reporting. See priv/js/package.json for the pinned @sentry/browser.
//
//   import {startBrowserErrors} from "../../deps/ash_enterprise_telemetry/priv/js/sentry_browser.js"
//   startBrowserErrors({dsn: meta.content})
//
// GlitchTip does not implement sessions, so the session integration is removed.
// Console breadcrumbs are off, because application logging is not meant for a third
// party. Tracing is not initialised: traces belong to the OTLP pipeline.

import * as Sentry from "@sentry/browser"

export const startBrowserErrors = ({dsn, tunnel = "/sentry/tunnel", environment, release} = {}) => {
  if (!dsn) return

  Sentry.init({
    dsn,
    tunnel,
    environment,
    release,
    tracesSampleRate: undefined,
    integrations: integrations =>
      integrations
        .filter(integration => integration.name !== "BrowserSession")
        .map(integration =>
          integration.name === "Breadcrumbs"
            ? Sentry.breadcrumbsIntegration({console: false})
            : integration
        )
  })
}
