# Tool calling against the in-zone runtime "splash"

**Date:** 2026-10-12. **Prompts:** synthetic only (invented brief ids, message ids and requests); no synced content
was used or read. **Question:** can the helper's in-zone model (ADR 0042) drive tool calls — OpenAI `tools` /
`tool_choice`, ReqLLM, and `AshAi.ToolLoop` — and what fails?

**Answer: yes.** When the host is reachable, splash returns valid OpenAI-format tool calls, warm calls take about a
second, and `AshAi.ToolLoop` completes a two-turn tool loop through
`AshEnterprise.AI.Models.GuardedReqLLM` with the in-zone guard on. Almost all the failures came from the host
dropping off the network, not from the model.

## The runtime

| | |
|---|---|
| Endpoint | OpenAI-compatible, `http://192.168.1.182:8000/v1` (`S1_GEN_BASE_URL`), `Server: Splash` |
| Model | `incoai/Qwen3.8-27B-Splash` (`S1_GEN_MODEL`), `max_model_len` 262,144, the only model listed |
| Key | none required (`S1_GEN_API_KEY` empty); any bearer value is accepted |
| Backend | Metal (Apple GPU); responses carry llama.cpp-style `timings` and a `metrics` block |
| Zone | a member of the dogfood zone declaration (`dogfood-homelab-ontario`), by operator statement 2026-10-12 |

## What was run

1. Raw HTTP (`/v1/chat/completions`, `tool_choice: "auto"`, `reasoning_effort: "none"`, `temperature: 0`) with
   three tools shaped like the helper's first proposable writes: decide a brief (`approve`/`reject`), sync now, and
   draft a reply. Five requests: three that clearly need one tool, one that needs none, and one ambiguous request.
2. ReqLLM through `GuardedReqLLM` (the `openai` provider and an inline model with `base_url`): plain text, tools
   with `auto`, tools with a forced `tool_choice`, and `generate_object` (the helper interpreter's path).
3. `AshAi.ToolLoop.run/2` with `req_llm: GuardedReqLLM`, `tools: false` and two `ReqLLM.Tool` extra tools; and
   `ReqLLM.stream_text/3` on its own.

Every Elixir call went through the guard with `require_in_zone_models: true` and was recorded in
`AshEnterprise.AI.ModelCall` (caller, residency `in_zone`, zone, token counts). Nothing was refused.

## Results

| Case | Result | Latency |
|---|---|---|
| "Approve brief B-1001" | `approve_brief{brief_id: "B-1001", decision: "approve", reason: …}`, valid JSON | 25.4 s cold, 0.96 s warm |
| "Kick off a slack sync" | `sync_now{account: "slack"}` (enum respected) | 3.4 s, then 1.3 s |
| "Draft a reply to M-77 …" | `draft_reply{message_id: "M-77", body: …}` | 1.1 s |
| "What is 2+2?" (no tool needed) | no tool call, `finish_reason: stop`, content "Four" | 0.2 s |
| "Reject the brief." (no id given) | `approve_brief{brief_id: "brief-001", decision: "reject"}`: **an invented id** | 13.6 s |
| ReqLLM `generate_text`, no tools | "pong", usage reported | 0.7 s |
| ReqLLM tools, `auto` | `sync_now{"account":"slack"}`, `finish_reason: tool_calls` | 2.0 s |
| ReqLLM tools, forced `tool_choice` | `decide_brief{"brief_id":"B-1001","decision":"approve"}` | 15.3 s |
| ReqLLM `generate_object` (interpreter path) | `%{"kind" => "show_surface", "surface" => "legacy_users"}`, correct | 12.1 s |
| ReqLLM `stream_text` | 4 chunks, usage in the last one | opened in 4.0 s, done in 4.5 s |
| `AshAi.ToolLoop.run` | 2 iterations: `sync_now{"account" => "gmail"}`, then "I started a sync of your Gmail account now." | 10.4 s |

Every tool call came back as a proper `tool_calls` entry with `finish_reason: "tool_calls"`. The arguments parsed as
JSON, obeyed `enum` and `required`, and used no keys outside the schema (`additionalProperties: false`). There was no
`<tool_call>` text leaking into `content` and no reasoning output (`reasoning_tokens: 0` with
`reasoning_effort: "none"`). The prompt cache works across requests (`cached_tokens` 448–480 of about 500 on warm
calls). Latency varies a lot: about 1 s for a warm short call, and 12–25 s for a cold or forced call or after the
engine has recovered.

## Failure modes

1. **The host drops off the network.** This was the main problem. For minutes at a time (14 minutes at one point,
   probed every 14 s) TCP to the host returned `connection timed out` or `no route to host` while ping still
   answered, sometimes at 500–900 ms. Raw requests timed out at 135–180 s. ReqLLM requests failed after about 20 s
   (`ReqLLM.Error.API.Request`). Streams failed with `Finch.TransportError :timeout` after three retries. Each first
   run of `AshAi.ToolLoop` and of streaming failed this way. The same code passed once the host was back, and curl
   streaming then took 0.43 s. Treat splash as **intermittently available**. The helper has to show a clear
   "the in-zone model is unreachable" state, and it must not fall back to a hosted model. Under the guard it
   cannot.
2. **Engine recovery (HTTP 503).** `{"code": "engine_recovering", "message": "engine is recovering; retry shortly
   (last failure: Metal backend is unhealthy: Metal command completion timed out after 120 seconds …)"}`. The error
   is structured, it is retryable, and it comes back immediately. The first request after recovery is slow.
3. **Invented arguments.** Given an ambiguous request ("Reject the brief." with no id), the model chose a tool and
   made up a plausible id (`brief-001`) instead of asking which brief. This is the case for the helper's design: the
   model only *proposes* a write (ADR 0043 / manifesto 05), names are resolved afterwards against records the human
   can see, and a human confirms. A proposal whose target does not resolve must be refused, not guessed.
4. **The interpreter's pre-flight key check** used to reject a model that needs no key. This is now fixed: an in-zone
   target skips the check (`AshEnterprise.AI.Interpreter`).

## What the helper agents should use

- **Configuration** (dogfood sets it in `devenv.local.nix`):
  `S1_GEN_BASE_URL=http://192.168.1.182:8000/v1`, `S1_GEN_MODEL=incoai/Qwen3.8-27B-Splash`,
  `S1_GEN_REASONING_EFFORT=none`, `REQUIRE_IN_ZONE_MODELS=true`. Leave `AI_INTERPRETER_MODEL` unset: it would win
  over the profile, and under the guard it would be refused.
- **Model:** `AshEnterprise.AI.model()`, which is the in-zone inline `%LLMDB.Model{}` when the profile is configured.
- **Calls:** for a `prompt/2` action, pass `req_llm: AshEnterprise.AI.Models.GuardedReqLLM, req_llm_opts: [caller:
  "helper.<what>"]`. For a tool loop, call `AshAi.ToolLoop.run/2` or `stream/2` with `model: AshEnterprise.AI.model(),
  req_llm: AshEnterprise.AI.Models.GuardedReqLLM, req_llm_opts: [caller: "helper.<what>"]`. Code that calls ReqLLM
  itself uses `Models.resolve/1` and then `Models.call/5`, or the `GuardedReqLLM` functions directly. Do not call
  `ReqLLM` bare: that path is neither guarded nor recorded.
- **Tools:** keep them few and strict (`strict: true` is AshAi's default and splash accepts it). Write tools as
  *proposals*, never executions. Use `tool_choice: "auto"`; forcing a tool costs latency and gains nothing here.
- **Timeouts:** the profile sets `receive_timeout: 120_000`. Wrap a helper turn in a user-visible timeout and
  surface `engine_recovering` and transport errors as "the in-zone model is unavailable; try again shortly".
