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

// A path segment that looks like a token: twenty or more characters of the
// base64url/hex/JWT alphabet, carrying both a letter and a digit (readable slugs
// and numeric ids keep their shape). The auth routes carry reset, confirm and
// magic-link tokens in their path; a span name never should.
const TOKEN_SEGMENT = /^[A-Za-z0-9_.-]{20,}$/
const tokenLike = segment =>
  TOKEN_SEGMENT.test(segment) && /\d/.test(segment) && /[a-zA-Z]/.test(segment)

// A page path with record ids and tokens removed, so a span name groups by page
// and carries no credential.
export const normalizePath = path =>
  path
    .replace(UUID, ":id")
    .split("/")
    .map(segment => (tokenLike(segment) ? ":token" : /^\d+$/.test(segment) ? ":id" : segment))
    .join("/")

// A URL or path with the token-like segments of its path removed; the query and
// fragment are kept as they are, and record ids too, since `url.full` names the one
// resource fetched.
export const redactPathTokens = url => {
  const end = url.search(/[?#]/)
  const [path, rest] = end === -1 ? [url, ""] : [url.slice(0, end), url.slice(end)]

  const redacted = path
    .split("/")
    .map(segment => (tokenLike(segment) ? ":token" : segment))
    .join("/")

  return redacted + rest
}

const REDACTED_ATTRIBUTES = ["url.full", "url.path", "http.target"]

// A span processor for the provider: the document-load spans put the page's location
// on `url.full`, and resource spans the resource URL there. `onEnd` is the one hook
// that sees every span of every instrumentation before it is exported, and the
// attributes are a plain record at that point, so rewriting them here keeps a token
// in the path off the export without reaching into each instrumentation. Place it
// before the exporting processor.
export class RedactPathAttributes {
  onStart() {}

  onEnd(span) {
    for (const key of REDACTED_ATTRIBUTES) {
      const value = span.attributes[key]
      if (typeof value === "string") span.attributes[key] = redactPathTokens(value)
    }
  }

  forceFlush() {
    return Promise.resolve()
  }

  shutdown() {
    return Promise.resolve()
  }
}

export const connectSpanName = path => `${normalizePath(path).slice(0, MAX_PAGE_LENGTH)} lv.connect`

export const toTraceparent = span => {
  const context = span.spanContext()
  return `00-${context.traceId}-${context.spanId}-0${context.traceFlags & 1}`
}

const TEXT_LABELLED_TAGS = new Set(["BUTTON", "ATLAS-BUTTON", "SUMMARY", "LABEL"])
const TEXT_LABELLED_ROLES = new Set(["button", "menuitem", "tab"])

const ROW_TAGS = new Set(["TR", "TD", "TH", "LI"])
const ROW_ROLES = new Set(["row", "gridcell", "cell", "listitem"])

// A control's text names it, but a link's or a row's text is whatever it displays:
// a customer, an address, an amount. Those need an explicit aria-label.
const textNamesControl = element =>
  TEXT_LABELLED_TAGS.has(String(element.tagName).toUpperCase()) ||
  TEXT_LABELLED_ROLES.has(element.getAttribute("role"))

const isRow = node =>
  Boolean(node && node.getAttribute) &&
  (ROW_TAGS.has(String(node.tagName).toUpperCase()) || ROW_ROLES.has(node.getAttribute("role")))

const shadowHost = element => (element.getRootNode ? element.getRootNode().host : undefined)

// A button inside a web component usually holds only a <slot>, whose own textContent
// is empty. The name is in what the host assigned to it.
const slottedText = element => {
  if (!element.querySelectorAll || isRow(shadowHost(element))) return ""

  return [...element.querySelectorAll("slot")]
    .flatMap(slot => (slot.assignedNodes ? slot.assignedNodes({flatten: true}) : []))
    .filter(node => !isRow(node))
    .map(node => node.textContent || "")
    .join(" ")
}

const ownName = element => {
  const text = textNamesControl(element) ? slottedText(element).trim() || element.textContent : ""
  return (element.getAttribute("aria-label") || text || "").trim().replace(/\s+/g, " ")
}

// An element's accessible name, falling back to its shadow host's for an icon-only
// button. Text and aria only: an input's value is user data and is never read.
export const controlLabel = element => {
  if (!element || !element.getAttribute) return undefined

  const label = ownName(element)
  if (label) return label.slice(0, MAX_LABEL_LENGTH)

  const host = shadowHost(element)
  return host ? controlLabel(host) : undefined
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
  let replying = null

  // The span the page is working for now: the reply being applied, else the latest
  // push still waiting for one.
  const currentSpan = () => {
    if (replying) return replying

    let latest
    for (const {span} of pending.values()) latest = span
    return latest
  }

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
        applyReply(span, message, callback)
        return
      }

      if (message.event === "phx_error") endTopic(message.topic, {code: STATUS_ERROR})
      if (message.event === "phx_close") endTopic(message.topic)
      callback(message)
    })

  // The span stays current while the reply is applied, because a hook that throws
  // during the patch is the error most worth joining to its trace.
  const applyReply = (span, message, callback) => {
    replying = span
    try {
      callback(message)
    } finally {
      replying = null
      span.end()
    }
  }

  // The page is going away, so no reply, error or close will arrive for what is in
  // flight. Ends those spans now, marked, so they are exported with the page.
  const endPending = () => {
    for (const [ref, entry] of pending) {
      pending.delete(ref)
      entry.span.setAttribute("ui.page.unloaded", true)
      entry.span.end()
    }
  }

  return {encode, decode, pendingCount: () => pending.size, currentSpan, endPending}
}

const isPlainPayload = payload =>
  payload && typeof payload === "object" && !(payload instanceof ArrayBuffer)
