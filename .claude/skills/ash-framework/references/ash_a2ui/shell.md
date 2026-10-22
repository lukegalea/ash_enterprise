# The shell: command palette, surface launcher and /open

`AshA2ui.Shell` is one key table, one slash grammar and one way to list what
a person may use. `AshA2ui.Shell.Component` draws it in a page: `ctrl+p`
opens the command palette and `ctrl+k` the surface launcher, from anywhere.

## Mount it once, in the layout

```heex
<.live_component
  module={AshA2ui.Shell.Component}
  id="a2ui-shell"
  host={MyAppWeb.Shell}
  context={@current_user}
/>
```

```javascript
import {AshA2uiShell} from "../../deps/ash_a2ui/priv/js/ash_a2ui_shell_hook.js"
let liveSocket = new LiveSocket("/live", Socket, {hooks: {AshA2uiShell, ...}})
```

- Mount it in the app layout so every page has it. Do not mount a second
  one on a page.
- A button opens it without a key:
  `phx-click={AshA2ui.Shell.Component.open("launcher")}`.

## The host supplies the lists and the effects

Implement `AshA2ui.Shell.Host`:

- `entries(context)` returns `%{commands: [...], surfaces: [...]}` in the
  ACP wire shapes: `AvailableCommand` maps (`"name"`, `"description"`,
  optional `"input" => %{"hint" => ...}`) and `SurfaceEntry` maps (`"id"`,
  `"title"`, `"group"`, `"description"`).
- Build both lists from the functions your ACP server uses for
  `available_commands_update` and `_ash/surfaces/list`. Then the web and a
  terminal client offer the same commands, and nothing is listed that the
  person cannot open.
- The shell filters and routes; it never widens a list. Apply doors and
  policies in `entries/1`, and check them again in `invoke/3`: the list
  was read when the shell opened.
- `entries/1` runs when the shell first opens on a page, not on mount.
- `invoke(invocation, context, socket)` returns `{:ok, socket}` (the shell
  closes) or `{:error, message}` (it stays open and shows the message).

## Invocations

| Typed | Invocation |
|---|---|
| `what is on today` | `{:prompt, text}`: send it to your agent |
| `/open calendar`, `/open people 3`, `/open people <id>` | `{:open_surface, entry, target}` |
| `/open`, `/home` | `:launcher` (handled by the component) |
| `/calendar week` | `{:command, command, ["week"]}` |
| `/agent` | `{:open_surface, entry, nil}`: a surface named directly |

- A target is `nil`, `{:nth, n}` or `{:record, id}`. The record id comes
  from the person: re-authorize it, as any deep link.
- Surface names match by id or title, ignoring case, spaces, dashes and
  underscores, or by a prefix only one surface has. An ambiguous name is an
  error, never a guess.
- A command with an input hint goes into the input to finish rather than
  running bare.

## Testing

- The hook pushes `"shell:open"` (`%{"mode" => "palette" | "launcher"}`),
  `"shell:move"` and `"shell:close"` to the component. In a LiveView test,
  push them with `render_hook(element(view, "#a2ui-shell"), "shell:open",
  %{"mode" => "palette"})`.
- The input is the form `#<id>-form` (`render_change` filters,
  `render_submit` runs the highlighted row). Rows are `#<id>-item-<n>`.
- `AshA2ui.Shell.route/2` and `items/3` are pure: test the grammar there.
