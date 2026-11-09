// Run with `node --test test/js/`. Exercises the socket wrapper with a fake
// tracer and serializer, so it needs no OpenTelemetry or Phoenix packages.

import assert from "node:assert/strict"
import {test} from "node:test"

import {
  controlFromEvent,
  controlLabel,
  createInteractionTracker,
  connectSpanName,
  createSocketTracing,
  normalizePath
} from "../../priv/js/socket_tracing.js"

const fakeTracer = () => {
  const spans = []
  return {
    spans,
    startSpan(name, options) {
      const span = {
        name,
        attributes: options.attributes,
        ended: false,
        spanContext: () => ({
          traceId: "0af7651916cd43dd8448eb211c80319c",
          spanId: "b7ad6b7169203331",
          traceFlags: 1
        }),
        setStatus(status) {
          this.status = status
        },
        end() {
          this.ended = true
        }
      }
      spans.push(span)
      return span
    }
  }
}

const fakeSerializer = () => {
  const encoded = []
  return {
    encoded,
    encode: (message, callback) => {
      encoded.push(message)
      callback(message)
    },
    decode: (raw, callback) => callback(raw)
  }
}

const setup = ({label} = {}) => {
  const tracer = fakeTracer()
  const serializer = fakeSerializer()
  const socket = createSocketTracing({
    serializer,
    tracer,
    getPagePath: () => "/app/widgets/123",
    interactions: {recent: () => label}
  })
  return {tracer, serializer, socket}
}

const eventMessage = payload => ({ref: "7", event: "event", topic: "lv:x", payload})

test("the traceparent goes in the value of a click event", () => {
  const {socket, serializer} = setup({label: "Activate"})
  socket.encode(eventMessage({type: "click", event: "activate", value: {id: "1"}}), () => {})

  assert.equal(
    serializer.encoded[0].payload.value._traceparent,
    "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  )
  assert.equal(serializer.encoded[0].payload.value.id, "1")
})

test("the traceparent goes in meta for a form, leaving the urlencoded value alone", () => {
  const {socket, serializer} = setup()
  socket.encode(eventMessage({type: "form", event: "save", value: "a=1&b=2"}), () => {})

  const {payload} = serializer.encoded[0]
  assert.equal(payload.value, "a=1&b=2")
  assert.match(payload.meta._traceparent, /^00-/)
})

test("the span is named with the page and control, and carries the contract attributes", () => {
  const {socket, tracer} = setup({label: "Activate"})
  socket.encode(eventMessage({type: "click", event: "a2ui:action", value: {}}), () => {})

  const [span] = tracer.spans
  assert.equal(span.name, "/app/widgets/:id Activate")
  assert.deepEqual(span.attributes, {
    "ui.page.path": "/app/widgets/:id",
    "ui.event.name": "a2ui:action",
    "ui.event.type": "click",
    "ui.control.label": "Activate"
  })
})

test("with no recent control the span falls back to the event name", () => {
  const {socket, tracer} = setup()
  socket.encode(eventMessage({type: "click", event: "refresh", value: {}}), () => {})

  assert.equal(tracer.spans[0].name, "/app/widgets/:id refresh")
  assert.equal("ui.control.label" in tracer.spans[0].attributes, false)
})

test("binary frames go to the serializer untouched and open no span", () => {
  const {socket, tracer, serializer} = setup()
  const payload = new ArrayBuffer(8)
  const frame = {ref: "9", event: "event", topic: "lvu:1", payload}

  socket.encode(frame, () => {})

  assert.equal(tracer.spans.length, 0)
  assert.equal(serializer.encoded[0], frame)
  assert.equal(serializer.encoded[0].payload, payload)
})

test("non-event messages open no span", () => {
  const {socket, tracer} = setup()
  socket.encode({ref: "1", event: "heartbeat", topic: "phoenix", payload: {}}, () => {})
  assert.equal(tracer.spans.length, 0)
})

test("the span ends on its own reply, not on another message", () => {
  const {socket, tracer} = setup()
  socket.encode(eventMessage({type: "click", event: "go", value: {}}), () => {})

  socket.decode({ref: "other", event: "phx_reply", payload: {}}, () => {})
  assert.equal(tracer.spans[0].ended, false)
  assert.equal(socket.pendingCount(), 1)

  let delivered = false
  socket.decode({ref: "7", event: "phx_reply", payload: {}}, () => {
    delivered = true
  })
  assert.equal(tracer.spans[0].ended, true)
  assert.equal(socket.pendingCount(), 0)
  assert.equal(delivered, true)
})

test("normalizePath replaces uuids and numeric segments", () => {
  assert.equal(
    normalizePath("/app/x/550e8400-e29b-41d4-a716-446655440000/edit"),
    "/app/x/:id/edit"
  )
  assert.equal(normalizePath("/app/42"), "/app/:id")
})

const element = attributes => ({
  getAttribute: name => attributes[name] ?? null,
  textContent: attributes.text ?? "",
  matches: selector => attributes.matches === selector || attributes.matches === true,
  tagName: attributes.tagName ?? "BUTTON"
})

test("a control's label is its aria-label or text, whitespace-collapsed and truncated", () => {
  assert.equal(controlLabel(element({"aria-label": "Close dialog"})), "Close dialog")
  assert.equal(controlLabel(element({text: "  Save \n changes  "})), "Save changes")
  assert.equal(controlLabel(element({text: "x".repeat(200)})).length, 80)
  assert.equal(controlLabel(element({})), undefined)
})

test("the control is found through the composed path, reaching into shadow DOM", () => {
  const inner = element({matches: false})
  const button = element({matches: true, text: "Publish"})
  const event = {composedPath: () => [inner, button], target: inner}
  assert.equal(controlFromEvent(event), "Publish")
})

test("a form submitter names the control", () => {
  const submitter = element({text: "Sign in"})
  assert.equal(controlFromEvent({submitter}), "Sign in")
})

test("an interaction expires after the window", () => {
  let now = 1000
  const tracker = createInteractionTracker({now: () => now})
  tracker.record({submitter: element({text: "Go"})})
  assert.equal(tracker.recent(), "Go")
  now += 5000
  assert.equal(tracker.recent(), undefined)
})

const push = (socket, {ref = "1", topic = "lv:1", event = "save", value = {}} = {}) =>
  socket.encode({event: "event", ref, topic, payload: {type: "click", event, value}}, () => {})

test("phx_error ends the pending spans of that topic and marks them failed", () => {
  const {tracer, socket} = setup({label: "Save"})
  push(socket, {ref: "1", topic: "lv:1"})
  push(socket, {ref: "2", topic: "lv:2"})

  socket.decode({event: "phx_error", ref: "99", topic: "lv:1", payload: {}}, () => {})

  assert.equal(tracer.spans[0].ended, true)
  assert.equal(tracer.spans[0].status.code, 2)
  assert.equal(tracer.spans[1].ended, false)
  assert.equal(socket.pendingCount(), 1)
})

test("phx_close ends the pending spans of that topic", () => {
  const {tracer, socket} = setup()
  push(socket, {ref: "1", topic: "lv:1"})

  socket.decode({event: "phx_close", ref: "99", topic: "lv:1", payload: {}}, () => {})

  assert.equal(tracer.spans[0].ended, true)
  assert.equal(socket.pendingCount(), 0)
})

test("an ordinary reply does not mark the span failed", () => {
  const {tracer, socket} = setup()
  push(socket, {ref: "1"})
  socket.decode({event: "phx_reply", ref: "1", topic: "lv:1", payload: {status: "ok"}}, () => {})
  assert.equal(tracer.spans[0].status, undefined)
})

test("an array hook payload is left as an array", () => {
  const {serializer, socket} = setup()
  push(socket, {value: [1, 2, 3]})
  assert.deepEqual(serializer.encoded[0].payload.value, [1, 2, 3])
})

test("a client-chosen event name is capped in the span name and the attribute", () => {
  const {tracer, socket} = setup()
  push(socket, {event: "e".repeat(5000)})

  assert.ok(tracer.spans[0].name.length <= 200, `name was ${tracer.spans[0].name.length}`)
  assert.ok(tracer.spans[0].attributes["ui.event.name"].length <= 128)
})

test("the connect span groups by page, so its name has no record id", () => {
  assert.equal(connectSpanName("/app/widgets/123"), "/app/widgets/:id lv.connect")
})

test("a row with phx-click never gives its text to the label", () => {
  const row = element({tagName: "TR", text: "Acme Corp  jane@acme.test  $1,200"})
  assert.equal(controlLabel(row), undefined)
})

test("a row's explicit accessible name is used", () => {
  const row = element({tagName: "TR", "aria-label": "Open vendor", text: "Acme Corp"})
  assert.equal(controlLabel(row), "Open vendor")
})

test("a generic element with phx-click does not give its text to the label", () => {
  assert.equal(controlLabel(element({tagName: "DIV", text: "Acme Corp"})), undefined)
  assert.equal(controlLabel(element({tagName: "TD", text: "Acme Corp"})), undefined)
  assert.equal(controlLabel(element({tagName: "LI", text: "Acme Corp"})), undefined)
})

test("a button's own text is used, capped", () => {
  assert.equal(controlLabel(element({tagName: "BUTTON", text: "Save"})), "Save")
  assert.equal(controlLabel(element({tagName: "ATLAS-BUTTON", text: "Save"})), "Save")
  assert.equal(controlLabel(element({tagName: "BUTTON", text: "x".repeat(500)})).length, 80)
})
