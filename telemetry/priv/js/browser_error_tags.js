// Tags a browser error event with the trace it happened in, under the same names the
// server's events use. Free of Sentry and OpenTelemetry imports so it can be tested
// without either. `otel_browser.js` registers where the active span comes from.

const VALID_TRACE_ID = /^(?!0{32})[0-9a-f]{32}$/
const VALID_SPAN_ID = /^(?!0{16})[0-9a-f]{16}$/

let activeSpan = () => undefined

export const setActiveSpanSource = source => {
  activeSpan = source
}

export const addTraceTags = (event, span) => {
  const context = span && span.spanContext ? span.spanContext() : undefined
  if (!context || !VALID_TRACE_ID.test(context.traceId) || !VALID_SPAN_ID.test(context.spanId)) {
    return event
  }

  return {...event, tags: {trace_id: context.traceId, span_id: context.spanId, ...event.tags}}
}

// Reporting must never fail because the tracing beside it did.
export const traceTagsBeforeSend = event => {
  try {
    return addTraceTags(event, activeSpan())
  } catch {
    return event
  }
}
