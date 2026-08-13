# Rules for the AG-UI transport (`AshA2ui.AgUi`)

Serve AshA2ui surfaces to AG-UI clients (CopilotKit chat UIs, or anything
speaking the AG-UI protocol) from an HTTP endpoint you own. Read the
External Transports doc topic for the full contract; these rules cover the
decisions that go wrong.

## The shape of an AG-UI endpoint

- An AG-UI server is ONE authenticated HTTP route: `POST` accepting a
  `RunAgentInput` JSON body, responding with chunked SSE
  (`Content-Type: text/event-stream`), one `AshA2ui.AgUi.encode_sse/1`
  frame per event.
- Every run MUST open with `run_started/2` and close with exactly one of
  `run_finished/3` or `run_error/2`. Map agent-loop failures to a
  `run_error/2` frame — never let the response just drop.
- Use `decode_run_input/1` on the body. It is hardened against hostile
  input (unknown roles dropped, malformed entries skipped); don't parse
  the body by hand.
- `AshA2ui.AgUi` is protocol-only by design: the Plug/controller, actor
  resolution, and task supervision live in YOUR app.

## Surfaces over AG-UI

- Emit a surface as `surface_activity(message_id, messages)` where
  `messages` came from `AshA2ui.Info.build_surface/2` or
  `AshA2ui.Dynamic.build_surface/2`. Never hand-assemble the
  `ACTIVITY_SNAPSHOT`/`a2ui_operations` wrapper.
- Keep the `message_id` STABLE per surface and re-emit the full
  (possibly extended) operations list to update the rendered surface in
  place. A new `message_id` renders a second surface in the transcript.
- Pin the wire version to the consuming renderer with the per-call
  override: `build_surface(ui, actor: actor, spec_version: "0.9.1")`.
  CopilotKit's shipped A2UI renderer speaks v0.9 only — do NOT emit v1.0
  messages at it, whatever its marketing says.

## The action round trip

- A client surface interaction arrives on the NEXT run as
  `forwardedProps.a2uiAction`; `decode_run_input/1` exposes it as
  `:a2ui_action`. When present, this run is an action dispatch — do not
  start an LLM turn for it.
- Convert with `decode_action/1` and route the resulting envelope through
  `AshA2ui.ActionHandler.handle/3` (declared surfaces) or
  `AshA2ui.Dynamic.handle_action/3` (agent-composed surfaces). Never
  invoke Ash actions directly from transport code — that skips the
  row-action allowlist, `visible_when` enforcement, and the error
  contract.
- Append the handler's follow-up messages to the surface's operation list
  and re-emit `surface_activity/2` under the same `message_id`.
- Serving actions requires remembering which surface a thread shows
  (Dynamic surfaces MUST be the server-held resolved struct). Scope that
  state by authenticated actor + thread id — a `threadId` is a client
  claim, not an identity.

## Human in the loop (pending surface actions)

- To pause a turn on a human decision: emit the decision request with
  `pending_tool_call/4` (start/args/end, NO `TOOL_CALL_RESULT`), emit the
  confirmation surface with `surface_activity/2`, then `run_finished/3`.
  Store the pending call (tool call id + the confirmation surface's id)
  scoped by authenticated actor + thread id.
- On every subsequent run, check `resolve_pending/2` BEFORE treating the
  run as a chat turn or an ordinary surface action. `{:resume, id, result}`
  means the user answered — re-enter your agent loop with `result` as the
  pending call's tool result.
- Resolution convention (in priority order): an action whose context
  carries the pending id under `"toolCallId"`, any action from the stored
  confirmation surface, or a `role: "tool"` message for the id in the run's
  history.
- The gated side effect stays in the host: execute it only on the user's
  explicit affirmative decision, actor-authorized — never from the LLM
  turn that asked for confirmation.

## Surface freshness

- `refresh_activity/2,3` re-emits a surface as an activity snapshot with a
  freshly rebuilt data model (declared UI modules and server-held Dynamic
  structs both work). Pass `:query_state`/`:context_state` to preserve the
  user's current filters and selections.
- While a run is open you can bridge PubSub record changes onto the
  stream: subscribe when the SSE response starts, flush each change as a
  `refresh_activity/3` re-emit, and unsubscribe when the run ends. See the
  External Transports topic for the pattern.

## Authentication

- Gate the route with your session/token pipeline. The actor comes from
  the authenticated session, NEVER from the `RunAgentInput` body.
- Keep `authorize?: true` (the default) on every build/handle call; do
  not weaken it on a network-facing transport.
