// The LiveView socket wrapper, free of OpenTelemetry imports so it can be tested
// without a browser or an SDK. `otel_browser.js` supplies the tracer.

export const TRACEPARENT_KEY = "_traceparent"

const MAX_LABEL_LENGTH = 80
const MAX_EVENT_LENGTH = 128
const MAX_PAGE_LENGTH = 128
const STATUS_ERROR = 2
const INTERACTION_WINDOW_MS = 1000
const CONTROL_SELECTOR =
  "button, a, summary, label, [role='button'], [role='link'], [role='menuitem'], [role='tab'], " +
  "atlas-button, [phx-click]"

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi

// A page path with record ids removed, so a span name groups by page.
export const normalizePath = path =>
  path
    .replace(UUID, ":id")
    .split("/")
    .map(segment => (/^\d+$/.test(segment) ? ":id" : segment))
    .join("/")

export const connectSpanName = path => `${normalizePath(path).slice(0, MAX_PAGE_LENGTH)} lv.connect`

export const toTraceparent = span => {
  const context = span.spanContext()
  return `00-${context.traceId}-${context.spanId}-0${context.traceFlags & 1}`
}

const TEXT_LABELLED_TAGS = new Set(["BUTTON", "ATLAS-BUTTON", "SUMMARY", "LABEL"])
const TEXT_LABELLED_ROLES = new Set(["button", "menuitem", "tab"])

// A control's text names it, but a link's or a row's text is whatever it displays:
// a customer, an address, an amount. Those need an explicit aria-label.
const textNamesControl = element =>
  TEXT_LABELLED_TAGS.has(String(element.tagName).toUpperCase()) ||
  TEXT_LABELLED_ROLES.has(element.getAttribute("role"))

// An element's accessible name. Text and aria only: an input's value is user data
// and is never read.
export const controlLabel = element => {
  if (!element || !element.getAttribute) return undefined

  const text = textNamesControl(element) ? element.textContent : ""
  const label = (element.getAttribute("aria-label") || text || "").trim().replace(/\s+/g, " ")

  return label ? label.slice(0, MAX_LABEL_LENGTH) : undefined
}

// Finds the control in an event's composed path, which reaches inside shadow DOM.
export const controlFromEvent = event => {
  if (event.submitter) return controlLabel(event.submitter)

  const path = event.composedPath ? event.composedPath() : [event.target]
  const control = path.find(node => node && node.matches && node.matches(CONTROL_SELECTOR))
  return controlLabel(control)
}

// Records the last interaction, so the span opened when LiveView pushes the event
// (which carries no element) can still name the control that caused it.
export const createInteractionTracker = ({now = () => Date.now(), target}) => {
  let last = null

  const record = event => {
    last = {label: controlFromEvent(event), at: now()}
  }

  if (target) {
    target.addEventListener("click", record, true)
    target.addEventListener("submit", record, true)
  }

  return {
    record,
    recent: () => (last && now() - last.at <= INTERACTION_WINDOW_MS ? last.label : undefined)
  }
}

// `encode` and `decode` for `new LiveSocket(...)`. One span per LiveView event,
// started on push and ended on the reply, or on the channel's error or close, because
// a crashing LiveView never replies.
//
// Binary frames (uploads) carry an ArrayBuffer payload, which has no event to name
// and no JSON to add a key to, so they go to Phoenix's serializer untouched.
export const createSocketTracing = ({serializer, tracer, getPagePath, interactions}) => {
  const pending = new Map()

  const annotate = (payload, traceparent) => {
    if (payload.type === "form") {
      // A form's value is an urlencoded string; LiveView merges `meta` into params.
      payload.meta = {...(payload.meta || {}), [TRACEPARENT_KEY]: traceparent}
    } else if (payload.value && typeof payload.value === "object" && !Array.isArray(payload.value)) {
      payload.value = {...payload.value, [TRACEPARENT_KEY]: traceparent}
    } else if (payload.value == null) {
      payload.value = {[TRACEPARENT_KEY]: traceparent}
    }
  }

  const encode = (message, callback) => {
    if (message.event === "event" && isPlainPayload(message.payload)) {
      const page = normalizePath(getPagePath()).slice(0, MAX_PAGE_LENGTH)
      const control = interactions && interactions.recent()
      const event = String(message.payload.event).slice(0, MAX_EVENT_LENGTH)

      const attributes = {
        "ui.page.path": page,
        "ui.event.name": event,
        "ui.event.type": String(message.payload.type)
      }
      if (control) attributes["ui.control.label"] = control

      const span = tracer.startSpan(`${page} ${control || event}`, {attributes})
      annotate(message.payload, toTraceparent(span))
      pending.set(message.ref, {span, topic: message.topic})
    }

    serializer.encode(message, callback)
  }

  // A channel-level frame's ref is not the push's, so it ends everything on its topic.
  const endTopic = (topic, status) => {
    for (const [ref, entry] of pending) {
      if (entry.topic !== topic) continue
      pending.delete(ref)
      if (status) entry.span.setStatus(status)
      entry.span.end()
    }
  }

  const decode = (raw, callback) =>
    serializer.decode(raw, message => {
      if (message.event === "phx_reply" && pending.has(message.ref)) {
        const {span} = pending.get(message.ref)
        pending.delete(message.ref)
        span.end()
      } else if (message.event === "phx_error") {
        endTopic(message.topic, {code: STATUS_ERROR})
      } else if (message.event === "phx_close") {
        endTopic(message.topic)
      }
      callback(message)
    })

  return {encode, decode, pendingCount: () => pending.size}
}

const isPlainPayload = payload =>
  payload && typeof payload === "object" && !(payload instanceof ArrayBuffer)
