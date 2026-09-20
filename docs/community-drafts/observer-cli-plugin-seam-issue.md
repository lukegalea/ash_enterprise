# Draft — GitHub issue for `zhongwencool/observer_cli`

**Venue:** zhongwencool/observer_cli issues. **Audience:** zhongwencool (maintainer; issue-first playbook).
**Status:** draft for Luke to submit. Nothing here gets posted by anyone else.
**Sourcing:** claims limited to what librarian research verified against 2.0.0 release/schema
(observer_cli is not vendored in this repo — no file/line refs cited).

---

## Title

`Discussion: a JSON data-payload seam for plugins — agent/automation consumption without a TTY`

---

## Body

First: 2.0 is a step-change. `--format json` with a versioned `observer_cli.cli/v1` envelope, a normative JSON Schema, stable exit codes, and identifier redaction is exactly what operator automation and AI-agent workflows need. Thank you for shipping it.

The gap we're hitting is extension. The 2.0 plugin seam lets a plugin contribute rendered TUI sections, but there's no way for a plugin to contribute *data* to the `--format json` envelope. Concretely: an agent driving the CLI non-interactively (SSH, cron, MCP-style tool) would love sections from a custom plugin — queue depths, app-specific gauges — but today that data only exists as TUI drawing output, which isn't machine-readable.

**Proposal:** a parallel data seam. Plugins gain a second callback returning JSON-serializable maps; the CLI merges them into the JSON envelope under a plugin-namespaced key, validated against the envelope version. TUI-only plugins that skip the callback are unaffected, and the published JSON Schema gains an optional `plugins` object. Agents get plugin data with no TTY involved, and the TUI stays the human surface.

Two smaller notes — happy to split into separate issues if cleaner:

1. **Supervision-tree depth.** Deep/wide trees (e.g. Oban: instance supervisor → per-queue supervisors → producers → N workers) appear to hit a rendering depth cap in the tree view. A configurable depth — honored in JSON output too — would let tooling pull larger sections for offline analysis.
2. **Mix task wrapper.** A thin `mix` task around the snapshot path would let projects capture the JSON envelope without escript/cookie plumbing.

Per your issue-first preference this is a discussion, not a PR — but glad to prototype the plugin data seam and iterate on your feedback.
