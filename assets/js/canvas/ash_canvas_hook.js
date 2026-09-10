/**
 * AshCanvas LiveView hook — the thin bridge between the `/canvas`
 * LiveView and the `<ash-canvas-graph>` element.
 *
 * Wiring (see docs/plans/2026-09-09-canvas-host-contract.md — names are
 * pinned):
 *
 *   - Server → client (once on mount): the LiveView pushes
 *     `canvas:graph` with `%{"revision" => ..., "nodes" => [...],
 *     "edges" => [...]}` (the JSON form of AshA2ui.Canvas.Graph). The
 *     hook hydrates the element via its `graph` property.
 *   - Client → server: the element dispatches a bubbling, composed
 *     `ash-canvas:select` CustomEvent (`detail.ref` = the node id); the
 *     hook forwards it as `pushEvent("canvas:select", {ref})`. Keeping
 *     the element's outbound contract a plain DOM event makes the element
 *     LiveView-agnostic (and testable outside a socket).
 *
 * The hook owns nothing else: selection semantics, keyboard model, layout
 * and styling all live in the element (ash_canvas_graph.js).
 */

const GRAPH_EVENT = "canvas:graph";
const SELECT_EVENT = "canvas:select";
const ELEMENT_TAG = "ash-canvas-graph";
const ELEMENT_SELECT_EVENT = "ash-canvas:select";

export const AshCanvas = {
  mounted() {
    // The LiveView renders the element inside this hook's container
    // (`phx-update="ignore"` keeps it across re-renders). Creating it
    // when absent keeps hydration working regardless of markup order.
    this.graphEl = this.el.querySelector(ELEMENT_TAG);
    if (!this.graphEl) {
      this.graphEl = document.createElement(ELEMENT_TAG);
      this.el.appendChild(this.graphEl);
    }

    this.onGraph = (payload) => {
      if (this.graphEl) this.graphEl.graph = payload;
    };
    this.handleEvent(GRAPH_EVENT, this.onGraph);

    this.onSelect = (event) => {
      const ref = event?.detail?.ref;
      if (typeof ref !== "string" || ref === "") return;
      this.pushEvent(SELECT_EVENT, {ref});
    };
    this.el.addEventListener(ELEMENT_SELECT_EVENT, this.onSelect);
  },

  destroyed() {
    if (this.onSelect) {
      this.el.removeEventListener(ELEMENT_SELECT_EVENT, this.onSelect);
    }
    this.onGraph = null;
    this.onSelect = null;
    this.graphEl = null;
  },
};

export default AshCanvas;
