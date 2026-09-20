# Draft — GitHub issue for `sorentwo/oban`

**Venue:** sorentwo/oban issues. **Audience:** sorentwo (Parker Selbert).
**Status:** draft for Luke to submit. Nothing here gets posted by anyone else.
**Facts verified against:** oban 2.24.1 source (`deps/oban`) — `lib/oban/queues/executor.ex`,
`producer.ex`, `watchman.ex`, `stager.ex`, `plugin.ex`, `lib/oban.ex`.

---

## Title

`Proposal: proc_lib labels for the long-lived supervision-tree processes (producers, stager, peer, notifier, plugins)`

---

## Body

Jobs already get a process label — `Oban.Queues.Executor.call/1` calls `Process.set_label(worker)` with the bare worker module, behind an OTP 26+ `function_exported?` guard (`lib/oban/queues/executor.ex:75`, `115–126`). Nice touch, but it covers only the transient half of the tree.

The long-lived processes carry registered names but no `proc_lib` label, so in `:observer`, observer_cli 2.0, LiveDashboard 0.9 process views, and crash reports they show up with no instance/queue context. With multiple Oban instances or a dozen queues, "which producer is this?" takes a lookup dance every time.

**Proposal:** one `Process.set_label/1` call per `init/1`, using the same OTP 26 guard as the executor. Suggested labels (any term is accepted; tuples stay sortable/prefixed):

| Process | Label |
|---|---|
| Instance supervisor (`Oban`) | `{:oban, name}` |
| Queue producer (`Oban.Queues.Producer`) | `{:oban_queue, queue_name}` |
| Queue supervisor (`Oban.Queues.Supervisor`) | `{:oban_queue_supervisor, queue_name}` |
| Watchman (`Oban.Queues.Watchman`) | `{:oban_watchman, queue_name}` |
| Stager / Peer / Notifier | `{:oban_stager, name}` etc. |
| Plugin children (`Oban.Plugin` — Cron, Lifeline, Pruner, …) | `{:oban_plugin, plugin_name}` |

Init sites are each module's `start_link/1` → `init/1` (`lib/oban/queues/producer.ex:25`, `lib/oban/queues/watchman.ex:15`, `lib/oban/stager.ex:22`, and the peer/notifier/plugin child specs) — roughly 10–15 lines total. No behaviour changes, no new deps, and labels surface automatically in every generic BEAM tool plus proc_lib crash reports.

One question: is the bare worker-module job label the committed shape, or would you consider enriching it with queue/job id? Happy either way.

Happy to put up a PR for the long-lived-process labels if you're open to it.
