# Documentation

Four kinds of document live here, and the difference between them is the point.

| | What it is | Read it when |
|---|---|---|
| [**QUESTIONS.md**](QUESTIONS.md) | The ledger. Every question an enterprise application must answer, our answer, and what proves it. | You want to know what this actually does before reading why. |
| [**COMPLIANCE.md**](COMPLIANCE.md) | The control map: named SOC 2, ISO 27001 and GDPR controls, where each stands, and what proves it. Generated from the ledger. | Someone has sent you a security questionnaire. |
| [**ROADMAP.md**](ROADMAP.md) | Where the gaps go, in what order, and what each choice beat. | You want to know where it is heading, or whether a decision was reasoned. |
| [**manifesto/**](manifesto/00-index.md) | The argument. Seven theses, one of which is the honest list of what is missing. | You want to know *why* anything here is shaped the way it is. |
| [**adr/**](adr/README.md) | The decisions. Nineteen records, each with the exit from it. | You disagree with something and want to know what it would cost to change. |
| [**plans/**](plans/README.md) | The specifications. Long-form designs for work that is proposed or partly built. | You are about to build one of them. |
| [**HANDOFF.md**](HANDOFF.md) | The state of play, plus findings that were expensive to discover. | You are picking this up in a new session. Start here. |

`roadmap.json` is the machine-readable source every status table in this repository renders from —
including the ones in the root `README.md`. It is rewritten by `mix ash_enterprise.roadmap` and checked
in CI, so a status cannot be right in one place and wrong in another. Edit the JSON, never a generated
table.

`screenshots/` holds real captures of the running application. Nothing in there is a mockup.

## Capturing screenshots

`scripts/screenshots/capture.mjs` drives a real browser against a running server. It has its own tiny
`package.json` (Playwright, nothing else) and is deliberately standalone from `assets/` and from `site/`:
capturing needs a browser *and* a running application, and neither the asset pipeline nor the marketing
site build should depend on either.

```bash
devenv shell -- mix ash_enterprise.bpmn.setup   # so there is something on the screens
devenv shell -- mix phx.server                  # in its own shell; it holds the _build lock
node scripts/screenshots/capture.mjs
```

`BASE_URL`, `EMAIL`, `PASSWORD` and `BROWSER` override the defaults
(`http://localhost:4000`, `admin@example.com`, `password1234`, `firefox`).

Three things about it are load-bearing rather than incidental.

**It signs in.** Every surface worth capturing is behind `live_user_required`, so the script visits
`/sign-in`, submits the form, and waits for the URL to change before doing anything else.

**It is Firefox at 1440×900 with `deviceScaleFactor: 2`.** Not a preference — **Chromium cannot rasterize
in the sandbox these were first captured in.** `page.screenshot()` hangs indefinitely under system Chrome
and under every `--disable-gpu` / `--single-process` / `--headless=old` combination tried; Firefox and
WebKit work. `BROWSER=chromium` is there for an environment where it does. The full finding is in
[`HANDOFF.md`](HANDOFF.md), and 1440 is also why the four workflow pages are grouped under one nav
dropdown: the bar already carries six items and wraps below about 1400px, so four more top-level buttons
would put a wrapped nav in every capture.

**It refuses to photograph a broken page**, which is the part worth copying into any other project. A
Phoenix error page screenshots very happily — the first attempt at documenting the process surfaces
produced a perfectly sharp, correctly cropped capture of a stacktrace and filed it as documentation. So
the script exits non-zero when either of two things happens:

- **A Content-Security-Policy refusal appears in the browser console.** Predicting a policy's effect from
  its directives verifies the *part*; loading the page and reading what the browser actually says
  verifies the *outcome*. This is how a long-standing CSP violation on the sign-in page was found — the
  default authentication banner fetches an image from a third-party host, `img-src 'self' data: blob:`
  refuses it, and the only report had ever been in a console nobody read.
- **The rendered body looks like an error page** — `at GET /`, `Internal Server Error`,
  `Something went wrong`, or `Error` in the document title.

It also hides the Tidewave dev toolbar, because leaving it in a documentation capture shows readers
something they will never have.

One caveat, so nobody trusts the gate further than it goes: the designer capture waits for
`.bjs-powered-by` — both the signal that bpmn-js booted *and* the bpmn.io watermark the licence requires
stay visible and unoverlapped — but a missing selector currently only warns and captures anyway, so a
non-compliant crop would not fail the run. **Not every image in `screenshots/` comes from this script**
either: the ones predating it were captured by hand.

### The live-update capture is a second script, and has to be

`scripts/screenshots/capture-live.mjs` records the legacy projection: a plain `INSERT INTO legacy.users`
in `psql`, and the surface over this application's *own* table gaining the row without a reload.

```bash
devenv shell -- mix ash_enterprise.legacy.project     # so the table is not empty to begin with
devenv shell -- mix phx.server                        # in its own shell
devenv shell -- node scripts/screenshots/capture-live.mjs
```

It must run **inside `devenv shell`**, unlike `capture.mjs`, because it shells out to `psql` and needs
`$PGPORT` — devenv shifts the port when 5432 is taken, so a hardcoded one connects to nothing on some
machines and to somebody else's Postgres on others.

Four things separate it from `capture.mjs`, and each was a bug first:

- **It signs in as `admin@legacy.example`, not `admin@example.com`.** The legacy rows belong to the
  `legacy` organization and both surfaces are tenant-scoped like everything else here, so the example
  tenant's admin sees an empty table on `/app/legacy-users` *and* `/app/directory`. Correct, and
  confusing, because an empty table looks exactly like a broken projection.
- **It verifies in the database, not the DOM.** A2UI's components render into shadow roots, so
  `innerText` on the surface returns the page chrome and a `shadowRoot` traversal does not reach the rows
  either. An earlier version asserted on that text and reported "looks empty" for a page rendering nine
  rows perfectly well.
- **It cleans up after itself.** Every run inserts a user; without a teardown the fourth run showed
  three identical people stacked above the seeded ones, which reads as the projection duplicating rows.
  The delete goes through `legacy.users`, so it exercises the projector's destroy path too.
- **It blocks Tidewave's network requests rather than only hiding the toolbar.** Hiding it is enough for
  a still; for a video, Firefox paints `Transferring data from tidewave.ai…` into the viewport while the
  request is in flight, and that lands in the recording as a caption on a marketing GIF.

The GIF is ffmpeg over Playwright's webm, trimmed to the last six seconds with `-sseof` — Playwright
records a context for its whole life, and the first version was sixteen seconds of mostly signing in, at
twenty-five times the file size of the frames that mattered.

## The three raw transcripts

`AshStrangler.md`, `BPMN.md` and `Strangler Fig Migrations for Postgres Schemas…md` at this level are
**unedited research transcripts**, kept for their citations. Each is explicitly superseded by a
document in `plans/`, and each is wrong in specifics that the plan corrects — `BPMN.md` describes a
different application entirely. Do not treat them as guidance.

## Suggested reading order

If you are evaluating: [QUESTIONS.md](QUESTIONS.md) → [COMPLIANCE.md](COMPLIANCE.md) →
[thesis 7](manifesto/07-what-we-do-not-have.md) → [ROADMAP.md](ROADMAP.md).

If you are building: [HANDOFF.md](HANDOFF.md) → [manifesto](manifesto/00-index.md) theses 1 and 3 →
the relevant skill in `.claude/skills/`.
