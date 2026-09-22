# Draft: message to Zach Daniel — ash_agent_tools is public, here's the method

**Channels:** GitHub and/or email — Luke sends both himself.
**Status:** DRAFT — Luke-gated. Assumes the repo flip has already happened
(fill in the real link before sending).

---

## Subject (email)

ash_agent_tools is public — this is what drove the patches

## Body

Zach,

I just made ash_agent_tools public: https://github.com/lukegalea/ash_agent_tools

It's a read-only introspection plane for Ash apps — the tooling layer we
built so coding agents work against resources instead of grepping source.
Describe a resource or action's actual contract, validate params by casting
them through Ash's own machinery without executing, explain why an action
would be forbidden, plus a supervised MCP daemon that serves all of it over
loopback. No hex release yet, no promotion — just visible.

Nearly everything I've pushed this week fell out of dogfooding it, so the
threads you've been reviewing have a common cause:

- usage_rules#88 — our agents eat usage-rules.md as a contract, and stale
  references in it break them quietly. Your ex_doc comment rebuilt the thing
  once; your round-two push ("just let ex_doc emit its warnings") is
  rebuilding it again, thinner. I also think your validate_additional_docs
  idea is the right eventual home and want to try it in ex_doc.
- opentelemetry_ash#75 — found by the trace sink that turns finished traces
  into agent-legible explanations (N+1s, policy denials, notification
  storms).
- ash#2955 — we generate static type contracts for code-interface actions in
  a fork; the dogfooding hit the get_by casting edges and noticed main had
  already fixed #1971, so the PR is just the regression tests.
- spark#293 — the semantic manifest is the piece all of the above wants:
  stable ids, source maps, action contracts, no app boot. Written to
  complement ex_doc, per your point about reusing its reference machinery.

Look at lib/ash_agent_tools.ex for the surface — describe/validate/context
are the core. If anything in there is shaped wrong for real Ash apps, you'll
see it faster than I will.

— Luke
