// The fixture page: a LiveView socket traced by the telemetry package's socket
// wrapper, with a very small tracer so the suite needs no OpenTelemetry JS packages.
import {
  createInteractionTracker,
  createSocketTracing,
  toTraceparent
} from "/vendor/telemetry/socket_tracing.js"

const hex = bytes =>
  Array.from(crypto.getRandomValues(new Uint8Array(bytes)), byte =>
    byte.toString(16).padStart(2, "0")
  ).join("")

const nanos = () => String(BigInt(Date.now()) * 1000000n)

const pendingExports = []

const send = span => {
  const request = fetch("/otel/v1/traces", {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      resourceSpans: [
        {
          resource: {attributes: []},
          scopeSpans: [{scope: {name: "fixture"}, spans: [span]}]
        }
      ]
    })
  })
  pendingExports.push(request)
}

const tracer = {
  startSpan(name, options = {}) {
    const traceId = hex(16)
    const spanId = hex(8)
    const startTimeUnixNano = nanos()
    return {
      spanContext: () => ({traceId, spanId, traceFlags: 1}),
      end() {
        send({
          traceId,
          spanId,
          name,
          kind: 1,
          startTimeUnixNano,
          endTimeUnixNano: nanos(),
          attributes: Object.entries(options.attributes || {}).map(([key, value]) => ({
            key,
            value: {stringValue: String(value)}
          })),
          status: {}
        })
      }
    }
  }
}

const interactions = createInteractionTracker({target: document})
const tracing = createSocketTracing({
  serializer: Phoenix.Serializer,
  tracer,
  getPagePath: () => window.location.pathname,
  interactions
})

let connectSpan = null
const connectTraceparent = () => {
  connectSpan = connectSpan || tracer.startSpan(`${window.location.pathname} lv.connect`)
  return toTraceparent(connectSpan)
}

window.__otelEndConnect = () => connectSpan && connectSpan.end()
window.__otelFlush = () => Promise.all(pendingExports.splice(0))

class DeepInner extends HTMLElement {
  connectedCallback() {
    const root = this.attachShadow({mode: "open"})
    root.innerHTML = `<button id="deep-button">Deep button</button>
      <span class="deep-text">Hidden in shadow</span>`
    root.querySelector("button").addEventListener("click", () => {
      root.querySelector(".deep-text").textContent = "Clicked"
    })
  }
}

class DeepBox extends HTMLElement {
  connectedCallback() {
    const root = this.attachShadow({mode: "open"})
    root.innerHTML = `<deep-inner></deep-inner>`
  }
}

customElements.define("deep-inner", DeepInner)
customElements.define("deep-box", DeepBox)

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: () => ({_csrf_token: csrfToken, _traceparent: connectTraceparent()}),
  encode: tracing.encode,
  decode: tracing.decode
})

liveSocket.connect()

if (window.location.pathname === "/console-error") console.error("fixture console error")
if (window.location.pathname === "/page-error") {
  window.setTimeout(() => {
    throw new Error("fixture page error")
  }, 0)
}
if (window.location.pathname === "/fetches-500") fetch("/boom")
