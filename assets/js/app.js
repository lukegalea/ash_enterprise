// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/ash_enterprise"
import topbar from "../vendor/topbar"

// --- A2UI ------------------------------------------------------------------
//
// A2UI renders UI from *data*, not code: the server sends a description of a
// surface and the client renders it from a catalog of components it already
// trusts. The model never emits markup and never emits script -- it references
// components that exist. See docs/manifesto/05-agents-are-users.md.
//
// Version note: no published @a2ui/lit release ships a v1.0 runtime (0.10.x
// exposes v0_8/v0_9 entry points only; the v1_0 directory carries schemas
// alone). ash_a2ui's hook is the v1.0-capable layer on top of the v0.9
// renderer, so we register the v0_9 catalog here and let the hook translate.
import "@a2ui/lit/v0_9"

// The BPMN designer and instance viewer. Imported from the package's own `priv/js` -- the same
// arrangement the A2UI hook uses -- so the library ships plain ESM and the host owns the
// bpmn-js dependency and the bundle.
//
// These import CSS, which esbuild emits as a second stylesheet alongside app.js. `root.html.heex`
// links it explicitly; without that link the diagram renders as unstyled boxes.
import {AshBpmnDesigner, AshBpmnViewer} from "../../deps/ash_bpmn/priv/js/ash_bpmn_designer.js"

// The DMN decision editor, on the same arrangement. dmn-js renders three
// different things behind one hook -- the requirements diagram, the decision
// table, the literal expression -- and ships no view switcher, so the tabs are
// server-rendered by the LiveView from the view list the hook reports.
import {AshDecisionsEditor} from "../../deps/ash_decisions/priv/js/ash_decisions_editor.js"
import {basicCatalog, A2uiLitElement, A2uiController, Context} from "@a2ui/lit/v0_9"
import {MessageProcessor, Catalog, ChoicePickerApi, ColumnApi} from "@a2ui/web_core/v0_9"
import {html, css, nothing} from "lit"
import {ContextProvider} from "@lit/context"
import {renderMarkdown} from "@a2ui/markdown-it"
import {AshA2ui, configureAshA2ui} from "../../deps/ash_a2ui/priv/js/ash_a2ui_hook.js"
import {createAshA2uiCatalog} from "../../deps/ash_a2ui/priv/js/ash_a2ui_catalog.js"

// The ash_a2ui catalog is a FACTORY, not a ready-made object, and it takes the
// lit runtime as a dependency deliberately: its custom elements must register
// against the SAME lit instance the renderer uses. Two copies of lit in the
// bundle means components register in a different custom-element registry and
// silently never render -- no error, just empty space where the table was.
//
// It validates its deps and throws, so a missing key fails loudly at startup
// rather than at first render. Note that esbuild happily bundles a call with
// the wrong shape: a green asset build proves nothing here.
const ashCatalog = createAshA2uiCatalog({
  Catalog,
  basicCatalog,
  ChoicePickerApi,
  ColumnApi,
  A2uiLitElement,
  A2uiController,
  lit: {html, css, nothing}
})

configureAshA2ui({
  MessageProcessor,
  // ONLY the merged catalog. It registers under the *same* catalog id the
  // encoder emits, and resolution is first-match:
  //
  //     const catalog = this.catalogs.find(c => c.id === catalogId)
  //
  // so passing basicCatalog first shadowed ashCatalog completely and every
  // override it exists to provide was dead code -- visible as single-choice
  // pickers rendering a stack of radio buttons instead of a <select>. It
  // already reuses every basic-catalog component it does not replace, so
  // nothing is lost by dropping basicCatalog from this list.
  catalogs: [ashCatalog],

  // Without a markdown renderer the basic catalog's Text component falls back
  // to `<span class="no-markdown-renderer">`, which prints headings as literal
  // `## Title` and -- much worse -- collapses EVERY Text on every surface to
  // one identical unstyled span. That erases the whole type hierarchy and
  // leaves the --a2ui-font-size-* scale as dead code.
  //
  // This is a hard requirement for A2UI v1.0, not a nicety: v1.0 removes the
  // h1-h5 Text variants entirely, so ash_a2ui's v1.0 encoder turns headings
  // into markdown `#` prefixes and there is no variant left to fall back on.
  //
  // renderMarkdown runs its output through DOMPurify, which matters because
  // these values come from the database rather than from a trusted author.
  markdown: {ContextProvider, context: Context.markdown, render: renderMarkdown}
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, AshA2ui, AshBpmnDesigner, AshBpmnViewer, AshDecisionsEditor},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

