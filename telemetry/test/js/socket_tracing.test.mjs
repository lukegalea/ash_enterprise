// Run with `node --test test/js/`. Exercises the socket wrapper with a fake
// tracer and serializer, so it needs no OpenTelemetry or Phoenix packages.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"

import {addTraceTags, setActiveSpanSource, traceTagsBeforeSend} from "../../priv/js/browser_error_tags.js"

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
  tagName: attributes.tagName ?? "BUTTON",
  querySelectorAll: selector =>
    selector === "slot"
      ? (attributes.slots ?? []).map(nodes => ({assignedNodes: () => nodes}))
      : [],
  getRootNode: () => (attributes.host ? {host: attributes.host} : {})
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

test("a shadow button takes its name from the slotted content", () => {
  const button = element({matches: true, slots: [[{textContent: "  Save \n changes "}]]})
  assert.equal(controlFromEvent({composedPath: () => [button], target: button}), "Save changes")
})

test("a button in any web component is named by its slot, whatever the host's tag", () => {
  const host = element({tagName: "MY-BUTTON", text: "ignored host text"})
  const button = element({matches: true, slots: [[{textContent: "Go"}]], host})
  assert.equal(controlLabel(button), "Go")
})

test("an icon-only shadow button takes the host's accessible name", () => {
  const host = element({tagName: "ATLAS-BUTTON", "aria-label": "Close"})
  const button = element({matches: true, slots: [[], []], host})
  assert.equal(controlLabel(button), "Close")
})

test("a shadow link takes the name of its button-like host", () => {
  const host = element({tagName: "ATLAS-BUTTON", text: "Award"})
  const link = element({tagName: "A", matches: true, slots: [[{textContent: "Award"}]], host})
  assert.equal(controlLabel(link), "Award")
})

test("a host that is a row gives nothing, even through a slot", () => {
  const host = element({tagName: "VENDOR-ROW", role: "row", text: "Acme Corp"})
  const button = element({matches: true, slots: [[{textContent: "Acme Corp"}]], host})
  assert.equal(controlLabel(button), undefined)
})

test("slotted row content never names a control", () => {
  const row = element({tagName: "TR", text: "Acme Corp"})
  const button = element({matches: true, slots: [[row]]})
  assert.equal(controlLabel(button), undefined)
})

test("a host's text is not used unless the host is itself a named control", () => {
  const host = element({tagName: "VENDOR-CARD", text: "Acme Corp"})
  const button = element({matches: true, slots: [[]], host})
  assert.equal(controlLabel(button), undefined)
})

const liveSpan = (traceId = "0af7651916cd43dd8448eb211c80319c", spanId = "b7ad6b7169203331") => ({
  spanContext: () => ({traceId, spanId, traceFlags: 1})
})

test("an error event gets the trace and span of the active span", () => {
  const event = addTraceTags({message: "x"}, liveSpan())
  assert.deepEqual(event.tags, {
    trace_id: "0af7651916cd43dd8448eb211c80319c",
    span_id: "b7ad6b7169203331"
  })
})

test("tags already on the event are kept", () => {
  const event = addTraceTags({tags: {page: "/a", trace_id: "mine"}}, liveSpan())
  assert.equal(event.tags.page, "/a")
  assert.equal(event.tags.trace_id, "mine")
})

test("with no span, or an invalid one, the event is unchanged", () => {
  assert.deepEqual(addTraceTags({message: "x"}, undefined), {message: "x"})
  const zeros = liveSpan("0".repeat(32), "0".repeat(16))
  assert.deepEqual(addTraceTags({message: "x"}, zeros), {message: "x"})
})

test("beforeSend reads the registered source, and survives one that throws", () => {
  setActiveSpanSource(() => liveSpan())
  assert.ok(traceTagsBeforeSend({}).tags.trace_id)

  setActiveSpanSource(() => {
    throw new Error("no")
  })
  assert.deepEqual(traceTagsBeforeSend({message: "x"}), {message: "x"})
  setActiveSpanSource(() => undefined)
})

test("the current span is the latest pending push, and the reply's during its callback", () => {
  const {tracer, socket} = setup()
  assert.equal(socket.currentSpan(), undefined)

  push(socket, {ref: "1"})
  push(socket, {ref: "2"})
  assert.equal(socket.currentSpan(), tracer.spans[1])

  let during
  socket.decode({event: "phx_reply", ref: "2", topic: "lv:1", payload: {}}, () => {
    during = socket.currentSpan()
  })

  assert.equal(during, tracer.spans[1])
  assert.equal(tracer.spans[1].ended, true)
  assert.equal(socket.currentSpan(), tracer.spans[0])
})

test("a throwing reply callback still ends the span", () => {
  const {tracer, socket} = setup()
  push(socket, {ref: "1"})

  assert.throws(() =>
    socket.decode({event: "phx_reply", ref: "1", topic: "lv:1", payload: {}}, () => {
      throw new Error("patch failed")
    })
  )
  assert.equal(tracer.spans[0].ended, true)
  assert.equal(socket.currentSpan(), undefined)
})

test("the usage comments give the path a sparse git dependency lands at", () => {
  for (const file of ["otel_browser.js", "sentry_browser.js"]) {
    const source = readFileSync(new URL(`../../priv/js/${file}`, import.meta.url), "utf8")
    assert.match(source, /deps\/ash_enterprise_telemetry\/telemetry\/priv\/js\//, file)
  }
})
