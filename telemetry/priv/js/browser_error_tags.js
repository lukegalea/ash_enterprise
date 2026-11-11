// Tags a browser error event with the trace it happened in, under the same names the
// server's events use, and makes the error an `exception` event on a span so the trace
// viewer's exceptions list has it too. Free of Sentry and OpenTelemetry imports so it can
// be tested without either. `otel_browser.js` registers where spans come from.

const VALID_TRACE_ID = /^(?!0{32})[0-9a-f]{32}$/
const VALID_SPAN_ID = /^(?!0{16})[0-9a-f]{16}$/

let activeSpan = () => undefined
let recordError = () => undefined
let traceUrlTemplate

export const setActiveSpanSource = source => {
  activeSpan = source
}

// `recorder(error)` records the error on a span (the active one, or a short
// `browser.error` span when none is) and returns that span.
export const setErrorRecorder = recorder => {
  recordError = recorder
}

// A template with `{trace_id}`, from <meta name="otel-trace-url">: the trace viewer's
// page for a trace. Unset, no link is added.
export const setTraceUrlTemplate = template => {
  traceUrlTemplate = template || undefined
}

export const addTraceTags = (event, span) => {
  const context = span && span.spanContext ? span.spanContext() : undefined
  if (!context || !VALID_TRACE_ID.test(context.traceId) || !VALID_SPAN_ID.test(context.spanId)) {
    return event
  }

  const tags = {trace_id: context.traceId, span_id: context.spanId}
  if (traceUrlTemplate) tags.trace_url = traceUrlTemplate.replace("{trace_id}", context.traceId)

  return {...event, tags: {...tags, ...event.tags}}
}

// The thrown value when Sentry kept it, else the first exception Sentry built.
export const errorOf = (event, hint) => {
  const original = hint && hint.originalException
  if (original instanceof Error) return original
  if (original && typeof original === "object" && original.message) return original

  const first = event && event.exception && event.exception.values && event.exception.values[0]
  if (first) return {name: first.type || "Error", message: first.value || ""}
  if (typeof original === "string") return {name: "Error", message: original}
  if (event && event.message) return {name: "Error", message: String(event.message)}
  return undefined
}

// Reporting must never fail because the tracing beside it did.
export const traceTagsBeforeSend = (event, hint) => {
  try {
    const error = errorOf(event, hint)
    const span = (error && recordError(error)) || activeSpan()
    return addTraceTags(event, span)
  } catch {
    return event
  }
}

// A console breadcrumb is dropped: application logging is not meant for a third party.
// A breadcrumb's text is capped, and a data: URL is cut to its media type. A development
// bundle with an inline source map fetches it as a multi-megabyte data: URL; its fetch
// breadcrumb then rode on the next error event and pushed it past the tunnel's body
// limit, so the error was refused instead of reported.
const MAX_BREADCRUMB_TEXT = 1024

const capText = value => {
  if (typeof value !== "string") return value
  if (value.startsWith("data:")) return `${value.slice(0, value.search(/[;,]/) + 1 || 32)}…`
  return value.length > MAX_BREADCRUMB_TEXT ? `${value.slice(0, MAX_BREADCRUMB_TEXT)}…` : value
}

export const capBreadcrumb = breadcrumb => {
  try {
    if (!breadcrumb || typeof breadcrumb !== "object") return breadcrumb
    if (breadcrumb.category === "console") return null
    const capped = {...breadcrumb, message: capText(breadcrumb.message)}
    if (capped.message === undefined) delete capped.message

    if (breadcrumb.data && typeof breadcrumb.data === "object") {
      capped.data = Object.fromEntries(
        Object.entries(breadcrumb.data).map(([key, value]) => [key, capText(value)])
      )
    }

    return capped
  } catch {
    return breadcrumb
  }
}
