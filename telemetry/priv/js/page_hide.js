// Page-unload delivery for browser spans, free of OpenTelemetry imports so it can be
// tested without a browser or an SDK. `otel_browser.js` supplies the exporter.
//
// A LiveView crash reloads the page. The span for the event that caused it is still
// open when the page goes away, and the batch processor's timer has not fired, so the
// span would never be exported and the server's crash span would keep a parent nobody
// ever received. On `pagehide` (and when the page turns hidden) the open spans are
// ended and whatever is pending is handed to `navigator.sendBeacon`, which the browser
// delivers after the page is gone.

const EXPORT_SUCCESS = 0
const EXPORT_FAILED = 1

// Wraps a span exporter. While `beaconing` is set, a batch goes out through
// `sendBeacon` as one same-origin POST with an `application/json` body (no custom
// headers, so no preflight); `sendBeacon` returning false (queue full) or being absent
// falls back to the wrapped exporter.
export const createBeaconExporter = ({inner, serialize, url, navigator: nav = globalThis.navigator}) => {
  let beaconing = false

  const beacon = spans => {
    if (!nav || typeof nav.sendBeacon !== "function") return false

    try {
      const body = new Blob([serialize(spans)], {type: "application/json"})
      return nav.sendBeacon(url, body) === true
    } catch (_error) {
      return false
    }
  }

  return {
    setBeaconing: value => {
      beaconing = value
    },
    export: (spans, resultCallback) => {
      if (beaconing && beacon(spans)) {
        resultCallback({code: EXPORT_SUCCESS})
      } else {
        inner.export(spans, resultCallback)
      }
    },
    shutdown: () => inner.shutdown(),
    forceFlush: () => (inner.forceFlush ? inner.forceFlush() : Promise.resolve())
  }
}

// Registers the listeners. `endOpenSpans` ends spans that are still waiting for a reply;
// `flush` exports what the processor holds. Returns a function that removes them.
export const installPageHideFlush = ({
  target = globalThis.window,
  doc = globalThis.document,
  exporter,
  endOpenSpans,
  flush
}) => {
  const run = () => {
    exporter.setBeaconing(true)
    try {
      endOpenSpans()
      return Promise.resolve(flush()).catch(() => undefined)
    } finally {
      // The flush starts its exports synchronously, so they have been sent by now;
      // a page that stays alive (a tab switch) goes back to the normal transport.
      exporter.setBeaconing(false)
    }
  }

  const onPageHide = () => {
    run()
  }

  const onVisibility = () => {
    if (doc.visibilityState === "hidden") run()
  }

  target.addEventListener("pagehide", onPageHide)
  doc.addEventListener("visibilitychange", onVisibility)

  return () => {
    target.removeEventListener("pagehide", onPageHide)
    doc.removeEventListener("visibilitychange", onVisibility)
  }
}
