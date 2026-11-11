// Browser tracing for a LiveView application. See socket_tracing.js for the wrapper
// itself and package.json here for the exact package versions to install.
//
//   // A git dependency with `sparse: "telemetry"` keeps the directory name; a path
//   // dependency or a Hex package does not.
//   import {startBrowserTracing} from "../../deps/ash_enterprise_telemetry/telemetry/priv/js/otel_browser.js"
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
import {JsonTraceSerializer} from "@opentelemetry/otlp-transformer"
import {resourceFromAttributes} from "@opentelemetry/resources"
import {BatchSpanProcessor} from "@opentelemetry/sdk-trace-base"
import {WebTracerProvider} from "@opentelemetry/sdk-trace-web"
import {Serializer} from "phoenix"

import {setActiveSpanSource} from "./browser_error_tags.js"
import {createBeaconExporter, installPageHideFlush} from "./page_hide.js"
import {
  connectSpanName,
  createInteractionTracker,
  createSocketTracing,
  RedactPathAttributes,
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

  const exporter = createBeaconExporter({
    inner: new OTLPTraceExporter({url: endpoint}),
    serialize: spans => JsonTraceSerializer.serializeRequest(spans),
    url: endpoint
  })

  const provider = new WebTracerProvider({
    resource: resourceFromAttributes({"service.name": serviceName}),
    // Redaction first: span processors run in order, and the batch exports what it is given.
    spanProcessors: [
      new RedactPathAttributes(),
      new BatchSpanProcessor(exporter, {scheduledDelayMillis: 200})
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

  // A reload (a LiveView crash causes one) must not lose the span of the event that
  // caused it: end what is open and hand the batch to sendBeacon.
  installPageHideFlush({
    exporter,
    endOpenSpans: () => socketTracing.endPending(),
    flush: () => provider.forceFlush()
  })

  let connectSpan = null

  // LiveView work runs outside any OpenTelemetry context, so the span for it is the
  // push in flight, or the connect until it ends.
  setActiveSpanSource(
    () =>
      trace.getActiveSpan() ||
      socketTracing.currentSpan() ||
      (connectSpan && connectSpan.isRecording() ? connectSpan : undefined)
  )

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
