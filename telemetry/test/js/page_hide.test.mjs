// Run with `node --test test/js/`. Exercises the page-unload delivery with fakes.

import assert from "node:assert/strict"
import {test} from "node:test"

import {createBeaconExporter, installPageHideFlush} from "../../priv/js/page_hide.js"
import {createInteractionTracker, createSocketTracing} from "../../priv/js/socket_tracing.js"

const fakeNavigator = (result = true) => {
  const beacons = []
  return {
    beacons,
    sendBeacon(url, body) {
      beacons.push({url, body})
      return result
    }
  }
}

const fakeInner = () => {
  const exported = []
  return {exported, export: (spans, cb) => (exported.push(spans), cb({code: 0})), shutdown: async () => {}}
}

const build = nav => {
  const inner = fakeInner()
  const exporter = createBeaconExporter({
    inner,
    serialize: spans => JSON.stringify({n: spans.length}),
    url: "/otel/v1/traces",
    navigator: nav
  })
  return {inner, exporter}
}

test("exports through the wrapped exporter until the page is going away", () => {
  const nav = fakeNavigator()
  const {inner, exporter} = build(nav)
  let result
  exporter.export([{}], r => (result = r))

  assert.equal(inner.exported.length, 1)
  assert.equal(nav.beacons.length, 0)
  assert.equal(result.code, 0)
})

test("beaconing sends one same-origin application/json POST body", async () => {
  const nav = fakeNavigator()
  const {inner, exporter} = build(nav)
  exporter.setBeaconing(true)
  let result
  exporter.export([{}, {}], r => (result = r))

  assert.equal(inner.exported.length, 0)
  assert.equal(nav.beacons.length, 1)
  assert.equal(nav.beacons[0].url, "/otel/v1/traces")
  assert.equal(nav.beacons[0].body.type, "application/json")
  assert.deepEqual(JSON.parse(await nav.beacons[0].body.text()), {n: 2})
  assert.equal(result.code, 0)
})

test("a refused beacon, or no sendBeacon, falls back to the wrapped exporter", () => {
  for (const nav of [fakeNavigator(false), {}]) {
    const {inner, exporter} = build(nav)
    exporter.setBeaconing(true)
    exporter.export([{}], () => undefined)
    assert.equal(inner.exported.length, 1)
  }
})

const fakeTarget = () => {
  const handlers = {}
  return {
    handlers,
    visibilityState: "visible",
    addEventListener: (name, fn) => (handlers[name] = fn),
    removeEventListener: name => delete handlers[name]
  }
}

const install = () => {
  const target = fakeTarget()
  const doc = fakeTarget()
  const calls = []
  const exporter = {setBeaconing: value => calls.push(`beaconing:${value}`)}
  const remove = installPageHideFlush({
    target,
    doc,
    exporter,
    endOpenSpans: () => calls.push("end"),
    flush: () => (calls.push("flush"), Promise.resolve())
  })
  return {target, doc, calls, remove}
}

test("pagehide ends open spans, then flushes with beaconing on", () => {
  const {target, calls} = install()
  target.handlers.pagehide()
  assert.deepEqual(calls, ["beaconing:true", "end", "flush", "beaconing:false"])
})

test("visibilitychange flushes only when the page turns hidden", () => {
  const {doc, calls} = install()
  doc.visibilityState = "visible"
  doc.handlers.visibilitychange()
  assert.deepEqual(calls, [])

  doc.visibilityState = "hidden"
  doc.handlers.visibilitychange()
  assert.deepEqual(calls, ["beaconing:true", "end", "flush", "beaconing:false"])
})

test("the listeners can be removed", () => {
  const {target, doc, remove} = install()
  remove()
  assert.equal(target.handlers.pagehide, undefined)
  assert.equal(doc.handlers.visibilitychange, undefined)
})

test("endPending ends the span of an event still waiting for its reply", () => {
  const ended = []
  const tracer = {
    startSpan: () => ({
      spanContext: () => ({traceId: "0af7651916cd43dd8448eb211c80319c", spanId: "b7ad6b7169203331", traceFlags: 1}),
      setAttribute(key, value) {
        this.attrs = {...this.attrs, [key]: value}
      },
      end() {
        ended.push(this)
      }
    })
  }
  const tracing = createSocketTracing({
    serializer: {encode: (_m, cb) => cb && cb(), decode: () => undefined},
    tracer,
    getPagePath: () => "/app",
    interactions: createInteractionTracker({})
  })

  tracing.encode({event: "event", topic: "lv:1", ref: "7", payload: {type: "click", event: "boom", value: {}}}, () => undefined)
  assert.equal(tracing.pendingCount(), 1)

  tracing.endPending()

  assert.equal(tracing.pendingCount(), 0)
  assert.equal(ended.length, 1)
  assert.equal(ended[0].attrs["ui.page.unloaded"], true)
})
