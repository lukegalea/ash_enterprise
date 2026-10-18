// InlineA2ui: one A2UI surface among several on the same LiveView page.
//
// The shipped AshA2ui hook listens for the page-wide "a2ui:messages" event
// and renders whichever surface it is sent: right for a page that hosts one
// surface, wrong for the agent chat, where every answer may carry its own
// composed table, calendar or board. This wraps it per container:
//
//   * its `data-surface-id` namespaces the event, so the server pushes
//     "a2ui:messages:<id>" to exactly this container;
//   * once mounted it asks the server for its surface ("assistant:surface"),
//     so a container that appears later (a finished answer, a reloaded
//     history, a reconnect) fetches the surface itself rather than relying on
//     a push that raced its mount;
//   * "a2ui:refused:<id>" replaces the skeleton with the server's reason when
//     a stored request no longer resolves.
//
// Everything else — rendering, actions, links — is the shipped hook's own;
// actions still go up as "a2ui:action" carrying their surfaceId, which the
// server routes to the surface it holds under that id.
import {AshA2ui} from "../../deps/ash_a2ui/priv/js/ash_a2ui_hook.js"

export const InlineA2ui = {
  ...AshA2ui,

  mounted() {
    const surfaceId = this.el.dataset.surfaceId
    const handleEvent = this.handleEvent.bind(this)

    this.handleEvent = (event, callback) =>
      handleEvent(event === "a2ui:messages" ? `a2ui:messages:${surfaceId}` : event, callback)

    AshA2ui.mounted.call(this)

    handleEvent(`a2ui:refused:${surfaceId}`, ({message}) => {
      const note = document.createElement("p")
      note.className = "text-sm text-foreground/70"
      note.textContent = message || "This view could not be shown."
      this.el.replaceChildren(note)
    })

    this.pushEvent("assistant:surface", {id: surfaceId})
  },
}
