import assert from "node:assert/strict"
import {test} from "node:test"

import {
  capBreadcrumb,
  errorOf,
  setActiveSpanSource,
  setErrorRecorder,
  setTraceUrlTemplate,
  traceTagsBeforeSend
} from "../../priv/js/browser_error_tags.js"

const span = (traceId, spanId) => ({spanContext: () => ({traceId, spanId})})
const TRACE = "0af7651916cd43dd8448eb211c80319c"
const SPAN = "b7ad6b7169203331"

test("an error is recorded on a span and the event is tagged with that span", () => {
  const recorded = []
  setActiveSpanSource(() => undefined)
  setErrorRecorder(error => {
    recorded.push(error)
    return span(TRACE, SPAN)
  })
  setTraceUrlTemplate(undefined)

  const error = new TypeError("boom")
  const event = traceTagsBeforeSend({exception: {values: [{type: "TypeError", value: "boom"}]}}, {
    originalException: error
  })

  assert.deepEqual(recorded, [error])
  assert.equal(event.tags.trace_id, TRACE)
  assert.equal(event.tags.span_id, SPAN)
  assert.equal(event.tags.trace_url, undefined)
})

test("the trace link is built from the template", () => {
  setErrorRecorder(() => span(TRACE, SPAN))
  setTraceUrlTemplate("https://traces.example/trace/{trace_id}")

  const event = traceTagsBeforeSend({message: "x"}, {})
  assert.equal(event.tags.trace_url, `https://traces.example/trace/${TRACE}`)
  setTraceUrlTemplate(undefined)
})

test("without an error the active span tags the event", () => {
  setErrorRecorder(() => {
    throw new Error("must not be called")
  })
  setActiveSpanSource(() => span(TRACE, SPAN))

  const event = traceTagsBeforeSend({}, {})
  assert.equal(event.tags.trace_id, TRACE)
})

test("a recorder that throws leaves the event as it was", () => {
  setErrorRecorder(() => {
    throw new Error("tracing broke")
  })
  const event = {message: "x"}
  assert.equal(traceTagsBeforeSend(event, {}), event)
})

test("errorOf prefers the thrown value, then Sentry's exception", () => {
  const thrown = new Error("thrown")
  assert.equal(errorOf({}, {originalException: thrown}), thrown)
  assert.deepEqual(errorOf({exception: {values: [{type: "E", value: "v"}]}}, {}), {
    name: "E",
    message: "v"
  })
  assert.equal(errorOf({}, {}), undefined)
})

test("a breadcrumb's data: URL is cut to its media type and long text is capped", () => {
  const huge = `data:application/json;base64,${"A".repeat(3_000_000)}`
  const crumb = capBreadcrumb({
    category: "fetch",
    message: "x".repeat(5000),
    data: {method: "GET", url: huge, status_code: 0}
  })

  assert.equal(crumb.data.url, "data:application/json;…")
  assert.equal(crumb.data.method, "GET")
  assert.equal(crumb.data.status_code, 0)
  assert.equal(crumb.message.length, 1025)
  assert.ok(JSON.stringify(crumb).length < 2_000)
})

test("an ordinary breadcrumb is unchanged", () => {
  const crumb = {category: "navigation", data: {from: "/a", to: "/b"}}
  assert.deepEqual(capBreadcrumb(crumb), crumb)
  assert.equal(capBreadcrumb(null), null)
})

test("a console breadcrumb is dropped", () => {
  const crumb = {category: "console", level: "log", message: "mount", data: {arguments: ["x"], logger: "console"}}
  assert.equal(capBreadcrumb(crumb), null)
})
