// Browser tracing for a LiveView application. See socket_tracing.js for the wrapper
// itself and package.json here for the exact package versions to install.
//
//   import {startBrowserTracing} from "../../deps/ash_enterprise_telemetry/priv/js/otel_browser.js"
//
//   const tracing = startBrowserTracing({serviceName: "my-app-browser"})
//   const liveSocket = new LiveSocket("/live", Socket, {
//     params: () => ({_csrf_token: csrfToken, _traceparent: tracing.connectTraceparent()}),
//     ...tracing.socketOptions,
//   })
//
// Enable it by rendering <meta name="otel-browser" content="on"> in the root layout.
// When that is absent everything here is inert, so the bundle costs nothing.

import {context, trace} from "@opentelemetry/api"
import {OTLPTraceExporter} from "@opentelemetry/exporter-trace-otlp-http"
import {registerInstrumentations} from "@opentelemetry/instrumentation"
import {DocumentLoadInstrumentation} from "@opentelemetry/instrumentation-document-load"
import {resourceFromAttributes} from "@opentelemetry/resources"
import {BatchSpanProcessor} from "@opentelemetry/sdk-trace-base"
import {WebTracerProvider} from "@opentelemetry/sdk-trace-web"
import {Serializer} from "phoenix"

import {
  connectSpanName,
  createInteractionTracker,
  createSocketTracing,
  toTraceparent
} from "./socket_tracing.js"

const enabled = () => document.querySelector('meta[name="otel-browser"]')?.content === "on"

const inert = {
  socketOptions: {},
  connectTraceparent: () => undefined,
  endConnect: () => undefined,
  flush: () => Promise.resolve()
}

export function startBrowserTracing({
  serviceName = "browser",
  endpoint = "/otel/v1/traces",
  getPagePath = () => window.location.pathname
} = {}) {
  if (!enabled()) return inert

  const provider = new WebTracerProvider({
    resource: resourceFromAttributes({"service.name": serviceName}),
    spanProcessors: [
      new BatchSpanProcessor(new OTLPTraceExporter({url: endpoint}), {scheduledDelayMillis: 200})
    ]
  })
  provider.register()

  // Picks up <meta name="traceparent">, so the page load is a child of the server
  // span that rendered it.
  registerInstrumentations({instrumentations: [new DocumentLoadInstrumentation()]})

  const tracer = trace.getTracer("ash-enterprise-telemetry.browser")
  const interactions = createInteractionTracker({target: document})
  const socketTracing = createSocketTracing({
    serializer: Serializer,
    tracer,
    getPagePath,
    interactions
  })

  let connectSpan = null

  const connectTraceparent = () => {
    connectSpan =
      connectSpan || tracer.startSpan(connectSpanName(getPagePath()), {}, context.active())
    return toTraceparent(connectSpan)
  }

  return {
    socketOptions: {encode: socketTracing.encode, decode: socketTracing.decode},
    connectTraceparent,
    endConnect: () => connectSpan && connectSpan.end(),
    flush: () => provider.forceFlush()
  }
}
