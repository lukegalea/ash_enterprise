/**
 * `<ash-canvas-graph>` — the visual canvas for the dev-only `/canvas`
 * surface (docs/plans/2026-09-09-canvas-host-contract.md; names pinned).
 *
 * Renders the host's Ash estate — applications, domains, resources and
 * their relationships — as a designed object graph via Cytoscape, with an
 * accessible outline tree alongside as the keyboard / screen-reader /
 * Playwright surface.
 *
 * ## Data in
 *
 * The `graph` property (hydrated by the AshCanvas hook) carries the JSON
 * form of `AshA2ui.Canvas.Graph`:
 *
 *     {revision: String, nodes: [{id, kind, label, metadata}],
 *      edges: [{kind: "contains"|"relationship", from, to, name}]}
 *
 * Node ids are the opaque refs selection dispatches. Containment roots are
 * derived client-side (nodes with no incoming `contains` edge).
 *
 * ## Events out
 *
 * `ash-canvas:select` — bubbling, composed CustomEvent with
 * `detail.ref` = the selected node id. Fired on canvas click, on Enter
 * (canvas or tree keyboard), and on tree row click. The hook forwards it
 * as the `canvas:select` LiveView event.
 *
 * ## Interaction + accessibility model
 *
 *   - Canvas region: `tabindex="0"`, `role="application"`, labeled.
 *     Arrow keys move selection over the containment tree (Up/Down =
 *     previous/next in tree order, Right = first child, Left = parent);
 *     Enter confirms (dispatches); Escape clears the local highlight.
 *   - Outline tree: `role="tree"` with `role="treeitem"` entries carrying
 *     `data-id` and `aria-selected`, nested `role="group"`s following
 *     containment, roving tabindex, and the same arrow/Enter/Escape model.
 *   - Pan/zoom via mouse/touch; explicit Fit / zoom controls.
 *   - `prefers-reduced-motion`: no animated layout or camera anywhere
 *     (Cytoscape animation is disabled unconditionally; CSS transitions
 *     collapse under a reduced-motion media rule).
 *
 * ## Design tokens
 *
 * Self-contained shadow styles on a `--cv-*` layer derived from the host's
 * `--ash-canvas-*` → `--ash-admin-*` / `--a2ui-*` customs with restrained
 * literal defaults (slate neutrals + one indigo family), so the canvas
 * reads as kin to the ash-admin catalog rather than a default Cytoscape
 * demo. The Cytoscape stylesheet itself reads the same tokens at build
 * time via getComputedStyle (canvas painting can't use CSS variables).
 */

import cytoscape from "cytoscape";
import {LitElement, html, css, nothing} from "lit";

const SELECT_EVENT = "ash-canvas:select";

// Fixed layout box: breadthfirst output is viewport-independent and every
// build of the same revision paints identically (fit rescales into view).
const LAYOUT_BOX = {x1: 0, y1: 0, x2: 1280, y2: 800};

// Spacing for the level wrapping in `#wrapLevels`. The band gap is larger than
// the row gap on purpose: rows within one depth should read as one block, and
// the space between depths is what makes containment legible.
const LEVEL_COLUMN_GAP = 28;
const LEVEL_ROW_GAP = 26;
const LEVEL_BAND_GAP = 48;

// Declutter thresholds: resource labels hide below this zoom when the
// graph is crowded; relationship names show above this zoom (always on
// hover regardless).
// Below this zoom a crowded graph drops its resource labels. It sits under the
// zoom a full fit lands on (about 0.75 for this application's 68 nodes) so the
// default view is labelled: at 0.8 the whole graph arrived as rows of unnamed
// boxes, which is decluttering applied to the one view nobody chose.
const RESOURCE_LABEL_ZOOM = 0.7;
const EDGE_LABEL_ZOOM = 1.15;
const CROWDED_NODE_COUNT = 24;

// Tree traversal order for the keyboard model.
const KIND_RANK = {application: 0, domain: 1, resource: 2};

export class AshCanvasGraph extends LitElement {
  static properties = {
    graph: {attribute: false},
  };

  #cy = null;
  #resizeObserver = null;
  #builtRevision = null;
  #treeModel = {roots: [], children: new Map(), parent: new Map(), order: []};
  #declutterScheduled = false;

  constructor() {
    super();
    this.graph = null;
    this.selectedId = null;
  }

  // --- shadow styles -------------------------------------------------------

  static styles = css`
    :host {
      /* Public token chain: --ash-canvas-* → admin/a2ui → literal. */
      --cv-surface: var(--ash-canvas-surface, var(--ash-admin-surface, var(--a2ui-color-surface, #ffffff)));
      --cv-surface-sunken: var(
        --ash-canvas-surface-sunken,
        var(--ash-admin-surface-sunken, var(--a2ui-color-background, #f8fafc))
      );
      --cv-text: var(--ash-canvas-text, var(--ash-admin-text, var(--a2ui-color-on-surface, #0f172a)));
      --cv-text-muted: var(--ash-canvas-text-muted, var(--ash-admin-text-muted, #475569));
      /* slate between 500/600: keeps the text → muted → faint hierarchy
       * while clearing WCAG AA (4.5:1) on surface, sunken and hover tints
       * (axe: 5.29 / 5.06 / 4.83:1) — #94a3b8 read 2.3–2.6:1. */
      --cv-text-faint: var(--ash-canvas-text-faint, var(--ash-admin-text-faint, #5d6d81));
      --cv-border: var(--ash-canvas-border, var(--ash-admin-border, var(--a2ui-color-border, #e2e8f0)));
      --cv-border-strong: var(--ash-canvas-border-strong, var(--ash-admin-border-strong, #cbd5e1));
      --cv-primary: var(
        --ash-canvas-primary,
        var(--ash-admin-primary, var(--a2ui-color-primary, #4f46e5))
      );
      --cv-primary-deep: var(--ash-canvas-primary-deep, #312e81);
      --cv-primary-subtle: var(
        --ash-canvas-primary-subtle,
        var(--ash-admin-primary-subtle, #eef2ff)
      );
      --cv-relationship: var(--ash-canvas-relationship, #7c3aed);
      --cv-grid: var(--ash-canvas-grid-dot, rgb(15 23 42 / 0.07));
      --cv-hover-tint: var(--ash-canvas-hover-tint, var(--ash-admin-hover-tint, #f1f5f9));
      --cv-focus: var(--ash-canvas-focus, var(--ash-admin-focus, var(--a2ui-color-primary, #4f46e5)));
      --cv-shadow: var(
        --ash-canvas-chrome-shadow,
        0 1px 2px rgb(15 23 42 / 0.06),
        0 4px 12px rgb(15 23 42 / 0.08)
      );
      --cv-radius-m: var(--ash-canvas-radius, 0.5rem);

      display: block;
      height: var(--ash-canvas-height, 100%);
      min-height: 30rem;
      color: var(--cv-text);
      font-family: inherit;
      font-size: 0.875rem;
      line-height: 1.5;
    }

    .cv-root {
      display: grid;
      grid-template-columns: minmax(0, 1fr) 17rem;
      height: 100%;
      min-height: inherit;
      background: var(--cv-surface);
      border: 1px solid var(--cv-border);
      border-radius: var(--cv-radius-m);
      overflow: hidden;
    }
    @media (max-width: 59.99rem) {
      .cv-root {
        grid-template-columns: minmax(0, 1fr);
        grid-template-rows: minmax(18rem, 1fr) auto;
      }
      .cv-tree {
        max-height: 16rem;
        border-left: none;
        border-top: 1px solid var(--cv-border);
      }
    }

    /* --- canvas region ---------------------------------------------------- */

    .cv-frame {
      position: relative;
      min-width: 0;
      min-height: 0;
      outline: none;
      background-color: var(--cv-surface-sunken);
      background-image: radial-gradient(circle, var(--cv-grid) 1px, transparent 1px);
      background-size: 22px 22px;
    }
    .cv-frame:focus-visible {
      outline: 2px solid var(--cv-focus);
      outline-offset: -2px;
    }
    /* The cytoscape container ONLY -- matched by its part name, not by being a
     * div. This selector used to be .cv-frame > div, which also matched
     * .cv-empty, .cv-controls and .cv-legend, stretching each of them across
     * the whole frame with inset: 0. Those rules then override only the sides
     * they name -- the legend sets left and bottom and inherits top: 0 and
     * right: 0 -- so the legend became a full-frame sheet of
     * color-mix(in srgb, var(--cv-surface) 88%, transparent) at z-index 5,
     * sitting on top of all three canvases. The graph was drawn correctly and
     * then covered by 88% opaque white, which is why it read as washed out at
     * roughly 12% strength while the canvas buffers held full-strength colour.
     *
     * It took as long as it did to find because pointer-events: none makes the
     * legend invisible to elementsFromPoint, and being a sibling rather than an
     * ancestor means no opacity or filter appears anywhere in the canvas's own
     * computed style. */
.cv-frame > [part="cytoscape"] {
      position: absolute;
      inset: 0;
    }

    .cv-empty {
      position: absolute;
      inset: 0;
      display: grid;
      place-items: center;
      color: var(--cv-text-faint);
      font-size: 0.8125rem;
      pointer-events: none;
    }

    /* --- canvas chrome (controls, legend) ---------------------------------- */

    .cv-controls {
      position: absolute;
      top: 0.75rem;
      right: 0.75rem;
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
      z-index: 5;
    }
    .cv-btn {
      display: grid;
      place-items: center;
      width: 1.75rem;
      height: 1.75rem;
      padding: 0;
      font: inherit;
      color: var(--cv-text-muted);
      background: var(--cv-surface);
      border: 1px solid var(--cv-border);
      border-radius: 0.375rem;
      box-shadow: var(--cv-shadow);
      cursor: pointer;
    }
    .cv-btn:hover {
      color: var(--cv-text);
      background: var(--cv-hover-tint);
    }
    .cv-btn:focus-visible {
      outline: 2px solid var(--cv-focus);
      outline-offset: 2px;
    }
    .cv-btn svg {
      width: 0.875rem;
      height: 0.875rem;
    }

    .cv-legend {
      position: absolute;
      left: 0.75rem;
      bottom: 0.75rem;
      display: flex;
      flex-wrap: wrap;
      gap: 0.375rem 1rem;
      padding: 0.375rem 0.625rem;
      font-size: 0.6875rem;
      letter-spacing: 0.02em;
      color: var(--cv-text-muted);
      background: color-mix(in srgb, var(--cv-surface) 88%, transparent);
      border: 1px solid var(--cv-border);
      border-radius: 0.375rem;
      box-shadow: var(--cv-shadow);
      z-index: 5;
      pointer-events: none;
    }
    .cv-legend .sample {
      display: inline-block;
      vertical-align: middle;
      margin-right: 0.3125rem;
    }
    .cv-legend .kind-app {
      width: 0.625rem;
      height: 0.4375rem;
      border-radius: 0.125rem;
      background: var(--cv-primary-deep);
    }
    .cv-legend .kind-domain {
      width: 0.625rem;
      height: 0.4375rem;
      border-radius: 0.125rem;
      background: var(--cv-primary-subtle);
      border: 1px solid var(--cv-primary);
    }
    .cv-legend .kind-resource {
      width: 0.625rem;
      height: 0.4375rem;
      border-radius: 0.125rem;
      background: var(--cv-surface);
      border: 1px solid var(--cv-border-strong);
    }
    .cv-legend .edge-contains {
      width: 1rem;
      height: 0;
      border-top: 2px solid var(--cv-border-strong);
    }
    .cv-legend .edge-relationship {
      width: 1rem;
      height: 0;
      border-top: 2px dashed var(--cv-relationship);
    }

    /* --- outline tree ------------------------------------------------------- */

    .cv-tree {
      display: flex;
      flex-direction: column;
      min-height: 0;
      background: var(--cv-surface);
      border-left: 1px solid var(--cv-border);
    }
    .cv-tree-header {
      padding: 0.625rem 0.75rem 0.5rem;
      border-bottom: 1px solid var(--cv-border);
    }
    .cv-tree-title {
      margin: 0;
      font-size: 0.6875rem;
      font-weight: 600;
      letter-spacing: 0.06em;
      text-transform: uppercase;
      color: var(--cv-text-faint);
    }
    .cv-tree-scroll {
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      padding: 0.375rem 0.375rem 0.75rem;
    }
    [role="tree"] {
      margin: 0;
      padding: 0;
      list-style: none;
    }
    [role="treeitem"] {
      display: block;
      margin: 0;
      padding: 0;
      list-style: none;
    }
    .tree-row {
      display: flex;
      align-items: center;
      gap: 0.4375rem;
      padding: 0.1875rem 0.4375rem 0.1875rem 0.3125rem;
      border-radius: 0.375rem;
      border-left: 2px solid transparent;
      cursor: pointer;
      white-space: nowrap;
      transition: background-color 120ms ease-out, border-color 120ms ease-out;
    }
    .tree-row:hover {
      background: var(--cv-hover-tint);
    }
    [role="treeitem"]:focus-visible > .tree-row {
      outline: 2px solid var(--cv-focus);
      outline-offset: -2px;
    }
    [aria-selected="true"] > .tree-row {
      background: var(--cv-primary-subtle);
      border-left-color: var(--cv-primary);
      font-weight: 600;
    }
    .tree-glyph {
      flex: none;
      width: 0.5rem;
      height: 0.5rem;
      border-radius: 0.125rem;
    }
    .tree-glyph-application {
      background: var(--cv-primary-deep);
    }
    .tree-glyph-domain {
      background: var(--cv-primary-subtle);
      outline: 1px solid var(--cv-primary);
      outline-offset: -1px;
    }
    .tree-glyph-resource {
      background: var(--cv-surface);
      outline: 1px solid var(--cv-border-strong);
      outline-offset: -1px;
      border-radius: 50%;
    }
    .tree-label {
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .tree-count {
      flex: none;
      font-size: 0.6875rem;
      color: var(--cv-text-faint);
    }
    [role="group"] {
      margin: 0;
      padding: 0 0 0 0.875rem;
      list-style: none;
      border-left: 1px solid var(--cv-border);
      margin-left: 0.55rem;
    }

    *, *::before, *::after {
      transition-duration: var(--cv-motion-duration, 140ms);
      transition-timing-function: ease-out;
      transition-property: background-color, border-color, color, opacity;
    }
    @media (prefers-reduced-motion: reduce) {
      *, *::before, *::after {
        transition-duration: 0.01ms !important;
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
      }
    }
  `;

  // --- lifecycle -------------------------------------------------------------

  firstUpdated() {
    this.#initCytoscape();
    if (this.graph) this.#buildGraph();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this.#resizeObserver?.disconnect();
    this.#resizeObserver = null;
    this.#cy?.destroy();
    this.#cy = null;
  }

  updated(changedProperties) {
    super.updated(changedProperties);
    if (changedProperties.has("graph") && this.#cy) this.#buildGraph();
  }

  /** The live Cytoscape instance — read-only, exposed for console/debug
   * access on this dev surface (same spirit as window.liveSocket). */
  get cy() {
    return this.#cy;
  }

  // --- rendering ---------------------------------------------------------------

  render() {
    const nodes = Array.isArray(this.graph?.nodes) ? this.graph.nodes : [];
    const status = nodes.length === 0 ? (this.graph ? "No graph objects." : "Loading graph…") : null;

    return html`
      <div class="cv-root">
        <div
          class="cv-frame"
          tabindex="0"
          role="application"
          aria-label="Ash object graph canvas — arrow keys move selection, Enter selects, Escape clears"
          @keydown=${(event) => this.#onCanvasKeydown(event)}
        >
          <div part="cytoscape" aria-hidden="true"></div>
          ${status ? html`<div class="cv-empty">${status}</div>` : nothing}
          ${nodes.length > 0
            ? html`
                <div class="cv-controls">
                  ${this.#controlButton("Zoom in", ICONS.zoomIn, () => this.#zoomBy(1.25))}
                  ${this.#controlButton("Zoom out", ICONS.zoomOut, () => this.#zoomBy(0.8))}
                  ${this.#controlButton("Fit graph to view", ICONS.fit, () => this.#fit())}
                </div>
                <div class="cv-legend" aria-hidden="true">
                  <span><span class="sample kind-app"></span>Application</span>
                  <span><span class="sample kind-domain"></span>Domain</span>
                  <span><span class="sample kind-resource"></span>Resource</span>
                  <span><span class="sample edge-contains"></span>contains</span>
                  <span><span class="sample edge-relationship"></span>relationship</span>
                </div>
              `
            : nothing}
        </div>
        <nav class="cv-tree" aria-label="Graph outline">
          <div class="cv-tree-header">
            <h2 class="cv-tree-title">Outline</h2>
          </div>
          <div class="cv-tree-scroll" @keydown=${(event) => this.#onTreeKeydown(event)}>
            ${nodes.length > 0 ? this.#renderTree() : nothing}
          </div>
        </nav>
      </div>
    `;
  }

  #controlButton(label, icon, onClick) {
    return html`
      <button type="button" class="cv-btn" title=${label} aria-label=${label} @click=${onClick}>
        ${icon}
      </button>
    `;
  }

  #renderTree() {
    const renderItem = (node, level) => {
      const children = this.#treeModel.children.get(node.id) || [];
      const selected = this.selectedId === node.id;
      const rovingTarget = this.selectedId ?? this.#treeModel.order[0]?.id;
      const actions = Array.isArray(node.metadata?.actions) ? node.metadata.actions.length : 0;

      return html`
        <div
          role="treeitem"
          data-id=${node.id}
          data-kind=${node.kind}
          aria-level=${level}
          aria-selected=${selected ? "true" : "false"}
          tabindex=${node.id === rovingTarget ? "0" : "-1"}
        >
          <div
            class="tree-row"
            @click=${() => this.#select(node.id, {confirm: true})}
          >
            <span class="tree-glyph tree-glyph-${node.kind}" aria-hidden="true"></span>
            <span class="tree-label">${node.label}</span>
            ${node.kind === "resource" && actions > 0
              ? html`<span class="tree-count">${actions}</span>`
              : nothing}
          </div>
          ${children.length > 0
            ? html`<div role="group">${children.map((child) => renderItem(child, level + 1))}</div>`
            : nothing}
        </div>
      `;
    };

    return html`
      <div role="tree" aria-label="Domains and resources">
        ${this.#treeModel.roots.map((node) => renderItem(node, 1))}
      </div>
    `;
  }

  // --- graph hydration -----------------------------------------------------

  #initCytoscape() {
    const container = this.renderRoot.querySelector(".cv-frame > div");
    if (!container) return;

    try {
      this.#cy = cytoscape({
        container,
        autoungrabify: true, // the layout is authoritative; dragging fights the DAG story
        autounselectify: true, // selection is managed via classes, not cytoscape's own
        boxSelectionEnabled: false,
        minZoom: 0.15,
        maxZoom: 2.5,
        layout: {name: "null"},
        style: cytoscapeStylesheet(this.#palette()),
        elements: [],
      });
    } catch (error) {
      // Environments without a 2D canvas context (or a hidden container at
      // init time) still get a fully working outline tree — selection,
      // keyboard model and events never depended on the painter.
      console.warn("ash-canvas-graph: canvas renderer unavailable, tree-only mode.", error);
      this.#cy = null;
      return;
    }

    this.#cy.on("tap", "node", (event) => {
      this.#select(event.target.id(), {confirm: true});
    });
    this.#cy.on("tap", (event) => {
      if (event.target === this.#cy) this.#clearSelection();
    });
    this.#cy.on("mouseover", "node", (event) => event.target.addClass("peek"));
    this.#cy.on("mouseout", "node", (event) => event.target.removeClass("peek"));
    this.#cy.on("mouseover", "edge", (event) => event.target.addClass("peek"));
    this.#cy.on("mouseout", "edge", (event) => event.target.removeClass("peek"));
    this.#cy.on("zoom", () => this.#scheduleDeclutter());

    // Container-driven resizes flow through the ResizeObserver below (the
    // single fit authority) — cy's own resize event would double-fit.
    this.#resizeObserver = new ResizeObserver(() => {
      this.#cy?.resize();
      this.#fit();
    });
    this.#resizeObserver.observe(this.renderRoot.querySelector(".cv-frame"));
  }

  #buildGraph() {
    const {nodes = [], edges = [], revision} = this.graph || {};
    if (revision && revision === this.#builtRevision) return;
    this.#builtRevision = revision ?? null;

    this.selectedId = null;
    this.#treeModel = buildTreeModel(nodes, edges);
    this.requestUpdate();

    const cy = this.#cy;
    if (!cy) return;

    cy.elements().remove();
    cy.add([
      ...nodes.map((node) => ({
        data: {
          id: node.id,
          kind: node.kind,
          label: node.label,
          actions: Array.isArray(node.metadata?.actions) ? node.metadata.actions.length : 0,
        },
      })),
      ...edges.map((edge, index) => ({
        data: {
          id: `e${index}:${edge.kind}:${edge.from}>${edge.to}`,
          kind: edge.kind,
          source: edge.from,
          target: edge.to,
          name: edge.name ?? "",
        },
      })),
    ]);

    // Deterministic containment layout: breadthfirst over the contains-DAG
    // only (relationship edges ride on top of placed endpoints). No
    // animation, ever — determinism and reduced-motion both demand it.
    const containmentEdges = cy.edges('edge[kind = "contains"]');
    const layout = cy
      .collection(cy.nodes(), containmentEdges)
      .layout({
        name: "breadthfirst",
        roots: cy.nodes().filter((node) =>
          this.#treeModel.roots.some((root) => root.id === node.id()),
        ),
        boundingBox: LAYOUT_BOX,
        directed: true,
        padding: 56,
        spacingFactor: 1.0,
        animate: false,
        animationDuration: 0,
      });
    layout.run();

    this.#wrapLevels();

    this.#fit();
    this.#applyDeclutter();
    this.#applySelectionClasses();
  }

  // breadthfirst puts every node of one depth on a single row, and this graph
  // is short and very wide: one application, a dozen domains, and ~50 resources
  // that all sit at depth 2. That row came out 16,478px across, so `fit()` asked
  // for zoom 0.055, got clamped at `minZoom` 0.15, and drew nodes small and
  // faint enough that the canvas read as empty — while the outline tree, the
  // node count and the edge count were all correct. Every check short of looking
  // at the pixels passed.
  //
  // So each depth is wrapped into rows no wider than the layout box, and the
  // depths are stacked top-down. That keeps what the old y-flip was for —
  // containment reading application → domains → resources, the orientation the
  // legend and the outline tree promise — while making the graph roughly as
  // wide as it is tall, which is the shape a viewport can actually show.
  #wrapLevels() {
    const cy = this.#cy;
    if (!cy || cy.nodes().length === 0) return;

    // breadthfirst anchors roots at the BOTTOM of its bounding box, so ordering
    // levels by descending y is ordering them root-first.
    const levels = new Map();
    cy.nodes().forEach((node) => {
      const key = Math.round(node.position().y);
      if (!levels.has(key)) levels.set(key, []);
      levels.get(key).push(node);
    });
    const ordered = [...levels.entries()].sort((a, b) => b[0] - a[0]).map(([, nodes]) => nodes);

    const width = LAYOUT_BOX.x2 - LAYOUT_BOX.x1;
    let y = LAYOUT_BOX.y1;

    cy.batch(() => {
      ordered.forEach((level) => {
        // Preserve the order breadthfirst chose within the level: it puts
        // siblings next to each other, so wrapping keeps a domain's resources
        // together instead of scattering them.
        level.sort((a, b) => a.position().x - b.position().x);

        const columnWidth = Math.max(...level.map((node) => node.width())) + LEVEL_COLUMN_GAP;
        const rowHeight = Math.max(...level.map((node) => node.height())) + LEVEL_ROW_GAP;
        const columns = Math.max(1, Math.min(level.length, Math.floor(width / columnWidth)));

        level.forEach((node, index) => {
          const row = Math.floor(index / columns);
          const column = index % columns;
          // Centre each row, including a short final one, so a wrapped level
          // reads as a block rather than as a ragged left edge.
          const inThisRow = Math.min(columns, level.length - row * columns);
          const rowWidth = inThisRow * columnWidth;

          node.position({
            x: LAYOUT_BOX.x1 + (width - rowWidth) / 2 + column * columnWidth + columnWidth / 2,
            y: y + row * rowHeight + rowHeight / 2,
          });
        });

        y += Math.ceil(level.length / columns) * rowHeight + LEVEL_BAND_GAP;
      });
    });
  }

  #fit() {
    this.#cy?.fit(undefined, 48);
    this.#scheduleDeclutter();
  }

  #zoomBy(factor) {
    const cy = this.#cy;
    if (!cy) return;
    cy.zoom({
      level: Math.min(Math.max(cy.zoom() * factor, cy.minZoom()), cy.maxZoom()),
      renderedPosition: {x: cy.width() / 2, y: cy.height() / 2},
    });
    this.#scheduleDeclutter();
  }

  // --- selection -------------------------------------------------------------

  #select(nodeId, {confirm}) {
    if (!this.#treeModel.order.some((node) => node.id === nodeId)) return;

    this.selectedId = nodeId;
    this.#applySelectionClasses();
    this.requestUpdate();

    const item = this.renderRoot.querySelector(`[data-id="${cssEscape(nodeId)}"]`);
    item?.scrollIntoView?.({block: "nearest"});

    if (confirm) this.#dispatchSelection(nodeId);
  }

  #clearSelection() {
    if (this.selectedId === null) return;
    this.selectedId = null;
    this.#applySelectionClasses();
    this.requestUpdate();
  }

  #dispatchSelection(nodeId) {
    this.dispatchEvent(
      new CustomEvent(SELECT_EVENT, {
        bubbles: true,
        composed: true,
        detail: {ref: nodeId},
      }),
    );
  }

  /**
   * Focus treatment: the selected node keeps full opacity with an accent
   * ring; its first-degree neighborhood (adjacent nodes + incident edges)
   * stays lit while everything else recedes. Cheap to compute, reads as
   * intentional.
   */
  #applySelectionClasses() {
    const cy = this.#cy;
    if (!cy) return;

    cy.batch(() => {
      cy.elements().removeClass("selected near dimmed edge-lit");

      const selectedId = this.selectedId;
      if (!selectedId) return;

      const selected = cy.getElementById(selectedId);
      const litEdges = selected.connectedEdges();
      const nearNodes = litEdges.connectedNodes().not(selected);

      selected.addClass("selected");
      nearNodes.addClass("near");
      litEdges.addClass("edge-lit");

      cy.elements()
        .not(selected)
        .not(nearNodes)
        .not(litEdges)
        .addClass("dimmed");
    });
  }

  // --- decluttering ------------------------------------------------------------

  #scheduleDeclutter() {
    if (this.#declutterScheduled) return;
    this.#declutterScheduled = true;
    requestAnimationFrame(() => {
      this.#declutterScheduled = false;
      this.#applyDeclutter();
    });
  }

  #applyDeclutter() {
    const cy = this.#cy;
    if (!cy) return;

    const zoom = cy.zoom();
    const crowded = cy.nodes().length > CROWDED_NODE_COUNT;
    const hideResourceLabels = crowded && zoom < RESOURCE_LABEL_ZOOM;
    const showEdgeLabels = zoom >= EDGE_LABEL_ZOOM;

    cy.batch(() => {
      cy.nodes('[kind = "resource"]').toggleClass("label-hidden", hideResourceLabels);
      cy.edges('[kind = "relationship"]').toggleClass("label-shown", showEdgeLabels);
    });
  }

  // --- keyboard model ---------------------------------------------------------

  #onCanvasKeydown(event) {
    if (this.#moveByKey(event)) event.preventDefault();
  }

  #onTreeKeydown(event) {
    const target = event.target.closest("[role='treeitem']");
    if (!target) return;
    if (this.#moveByKey(event, target.dataset.id)) event.preventDefault();
  }

  /**
   * The shared keyboard model (canvas region and tree rows):
   * Up/Down = previous/next in containment order, Right = first child,
   * Left = parent, Enter/Space = confirm selection, Escape = clear.
   * `focusedId` (tree context only) makes Enter act on the focused
   * treeitem rather than the ambient selection. Returns true when the
   * key was handled (caller prevents default).
   */
  #moveByKey(event, focusedId = null) {
    const model = this.#treeModel;
    if (model.order.length === 0) return false;

    const key = event.key;
    const currentId = this.selectedId ?? focusedId;
    const currentIndex = currentId ? model.order.findIndex((n) => n.id === currentId) : -1;

    const focusItem = (nodeId) => {
      const item = this.renderRoot.querySelector(`[data-id="${cssEscape(nodeId)}"]`);
      item?.focus();
    };

    switch (key) {
      case "ArrowDown":
      case "ArrowUp": {
        const step = key === "ArrowDown" ? 1 : -1;
        let nextIndex = currentIndex + step;
        if (nextIndex < 0 || nextIndex >= model.order.length) nextIndex = 0; // wrap
        const next = model.order[nextIndex];
        this.#select(next.id, {confirm: false});
        focusItem(next.id);
        this.#panToIfNeeded(next.id);
        return true;
      }
      case "ArrowRight": {
        const children = (currentId && model.children.get(currentId)) || model.roots;
        if (!children || children.length === 0) return true;
        this.#select(children[0].id, {confirm: false});
        focusItem(children[0].id);
        this.#panToIfNeeded(children[0].id);
        return true;
      }
      case "ArrowLeft": {
        const parentId = currentId && model.parent.get(currentId);
        if (parentId) {
          this.#select(parentId, {confirm: false});
          focusItem(parentId);
          this.#panToIfNeeded(parentId);
        }
        return true;
      }
      case "Enter":
      case " ": {
        const confirmId = focusedId ?? this.selectedId;
        if (confirmId) {
          this.#select(confirmId, {confirm: false});
          this.#dispatchSelection(confirmId);
        }
        return true;
      }
      case "Escape":
        this.#clearSelection();
        return true;
      default:
        return false;
    }
  }

  /** Pans the camera only when the target node falls outside the viewport. */
  #panToIfNeeded(nodeId) {
    const cy = this.#cy;
    if (!cy) return;
    const node = cy.getElementById(nodeId);
    if (node.empty()) return;
    const box = node.renderedBoundingBox();
    if (
      box.x1 < 0 ||
      box.y1 < 0 ||
      box.x2 > cy.width() ||
      box.y2 > cy.height()
    ) {
      cy.center(node);
    }
  }

  // --- theming ------------------------------------------------------------------

  #palette() {
    const computed = getComputedStyle(this);
    const token = (name, fallback) => computed.getPropertyValue(name).trim() || fallback;
    const cascade = (specific, shared, fallback) => token(specific, token(shared, fallback));

    return {
      fontFamily: computed.fontFamily || "inherit",
      text: cascade("--ash-canvas-text", "--ash-admin-text", "#0f172a"),
      textMuted: cascade("--ash-canvas-text-muted", "--ash-admin-text-muted", "#475569"),
      border: cascade("--ash-canvas-border", "--ash-admin-border", "#e2e8f0"),
      borderStrong: cascade("--ash-canvas-border-strong", "--ash-admin-border-strong", "#cbd5e1"),
      surface: cascade("--ash-canvas-surface", "--ash-admin-surface", "#ffffff"),
      primary: cascade("--ash-canvas-primary", "--ash-admin-primary", "#4f46e5"),
      primaryDeep: token("--ash-canvas-primary-deep", "#312e81"),
      primarySubtle: cascade("--ash-canvas-primary-subtle", "--ash-admin-primary-subtle", "#eef2ff"),
      relationship: token("--ash-canvas-relationship", "#7c3aed"),
      success: cascade("--ash-canvas-success", "--ash-admin-success", "#047857"),
    };
  }
}

/**
 * Builds the outline model: containment children per node, parent links,
 * and a flattened depth-first order (roots by kind rank then label) that
 * the keyboard model walks.
 */
function buildTreeModel(nodes, edges) {
  const byId = new Map(nodes.map((node) => [node.id, node]));
  const children = new Map();
  const parent = new Map();
  const contained = new Set();

  for (const edge of edges) {
    if (edge.kind !== "contains") continue;
    if (!byId.has(edge.from) || !byId.has(edge.to) || edge.from === edge.to) continue;
    if (!children.has(edge.from)) children.set(edge.from, []);
    children.get(edge.from).push(byId.get(edge.to));
    parent.set(edge.to, edge.from);
    contained.add(edge.to);
  }

  const sortSiblings = (list) =>
    list.sort(
      (a, b) =>
        (KIND_RANK[a.kind] ?? 9) - (KIND_RANK[b.kind] ?? 9) ||
        a.label.localeCompare(b.label) ||
        a.id.localeCompare(b.id),
    );

  for (const list of children.values()) sortSiblings(list);

  let roots = nodes.filter((node) => !contained.has(node.id));
  if (roots.length === 0) roots = [...nodes]; // degenerate cycle: flatten everything
  sortSiblings(roots);

  const order = [];
  const walk = (node) => {
    order.push(node);
    for (const child of children.get(node.id) || []) walk(child);
  };
  for (const root of roots) walk(root);

  return {roots, children, parent, order};
}

/** Cytoscape paints on canvas, so its stylesheet needs concrete colors —
 * the palette is resolved from the host's CSS custom properties at init. */
function cytoscapeStylesheet(palette) {
  return [
    {
      selector: "node",
      style: {
        // Nodes carry their display name as `data.label` (see `#buildGraph`).
        // Without this mapping cytoscape draws every node as an empty box, and
        // the `label-hidden` declutter class below spends its time hiding a
        // label that was never shown.
        label: "data(label)",
        "font-family": palette.fontFamily,
        color: palette.text,
        shape: "round-rectangle",
        "border-width": 1,
        "border-opacity": 1,
        "text-valign": "center",
        "text-halign": "center",
        "text-wrap": "wrap",
        "font-weight": 500,
        "z-index": 10,
      },
    },
    {
      // The anchor: largest, deepest fill, strongest weight.
      selector: 'node[kind = "application"]',
      style: {
        width: 176,
        height: 56,
        "background-color": palette.primaryDeep,
        "border-color": palette.primaryDeep,
        color: "#ffffff",
        "font-size": 15,
        "font-weight": 700,
        "text-max-width": 150,
      },
    },
    {
      selector: 'node[kind = "domain"]',
      style: {
        width: 136,
        height: 42,
        "background-color": palette.primarySubtle,
        "border-color": palette.primary,
        "border-width": 1.5,
        color: palette.primaryDeep,
        "font-size": 12.5,
        "font-weight": 600,
        "text-max-width": 120,
      },
    },
    {
      selector: 'node[kind = "resource"]',
      style: {
        width: 104,
        height: 32,
        "background-color": palette.surface,
        "border-color": palette.borderStrong,
        color: palette.text,
        "font-size": 10.5,
        "font-weight": 500,
        "text-max-width": 92,
      },
    },
    {
      // Soft structural links: hairline, no arrow, recede behind nodes.
      selector: 'edge[kind = "contains"]',
      style: {
        width: 1.5,
        "line-color": palette.borderStrong,
        "line-style": "solid",
        "curve-style": "bezier",
        "target-arrow-shape": "none",
        opacity: 0.9,
        "z-index": 1,
      },
    },
    {
      // Relationships: a distinct hue + dash + arrowhead.
      selector: 'edge[kind = "relationship"]',
      style: {
        width: 1.75,
        "line-color": palette.relationship,
        "line-style": "dashed",
        "line-dash-pattern": [5, 4],
        "curve-style": "bezier",
        "target-arrow-shape": "triangle",
        "target-arrow-fill": "filled",
        "arrow-scale": 0.75,
        opacity: 0.75,
        "z-index": 2,
        label: "data(name)",
        "font-size": 9,
        color: palette.textMuted,
        "text-background-color": palette.surface,
        "text-background-opacity": 1,
        "text-background-padding": 2,
        "text-background-shape": "roundrectangle",
        "text-opacity": 0,
      },
    },

    // --- interaction states -------------------------------------------------
    {
      selector: "node.peek",
      style: {
        "border-color": palette.primary,
        "overlay-color": palette.primary,
        "overlay-opacity": 0.06,
        "overlay-padding": 6,
      },
    },
    {
      selector: "node.selected",
      style: {
        "border-color": palette.primary,
        "border-width": 2.5,
        "overlay-color": palette.primary,
        "overlay-opacity": 0.14,
        "overlay-padding": 8,
      },
    },
    {
      selector: "node.dimmed",
      style: {opacity: 0.3, "text-opacity": 0.2},
    },
    {
      selector: "node.label-hidden",
      style: {"text-opacity": 0},
    },
    {
      selector: "node.label-hidden.peek, node.peek",
      style: {"text-opacity": 1},
    },
    {
      selector: "edge.peek",
      style: {
        opacity: 1,
        width: 2.25,
        "text-opacity": 1,
      },
    },
    {
      selector: "edge.label-shown",
      style: {"text-opacity": 1},
    },
    {
      selector: "edge.dimmed",
      style: {opacity: 0.12},
    },
    {
      selector: "edge.edge-lit",
      style: {opacity: 1, width: 2.25},
    },
    {
      selector: "edge.edge-lit[kind = 'relationship']",
      style: {"line-color": palette.relationship},
    },
  ];
}

const ICONS = {
  zoomIn: svgIcon(
    "M12 5v14M5 12h14",
  ),
  zoomOut: svgIcon("M5 12h14"),
  fit: svgIcon("M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3"),
};

function svgIcon(path) {
  return html`<svg
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    stroke-width="1.75"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
  >
    <path d=${path}></path>
  </svg>`;
}

function cssEscape(value) {
  if (window.CSS?.escape) return window.CSS.escape(value);
  return String(value).replace(/([^a-zA-Z0-9_-])/g, "\\$1");
}

if (!customElements.get("ash-canvas-graph")) {
  customElements.define("ash-canvas-graph", AshCanvasGraph);
}

export default AshCanvasGraph;
