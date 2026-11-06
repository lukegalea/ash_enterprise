import path from "node:path";
import {defineConfig} from "@playwright/test";

// The application under test is the dev server, which reads its port from
// PORT (config/runtime.exs; default 4000). The default here is deliberately
// NOT 4000: the workspace may already have a server on the default port, and
// this suite must own the process it starts. Override with E2E_PORT (or
// point E2E_BASE_URL at an already-running server).
const port = process.env.E2E_PORT ?? "4100";
const baseURL = process.env.E2E_BASE_URL ?? `http://127.0.0.1:${port}`;
// The webServer command must run from the repo root: mix finds mix.exs in its
// working directory, and this config lives in assets/.
const repoRoot = path.resolve(__dirname, "..");

// Specs that run a credential activation through the demo registry (see projects).
const ACTIVATING = ["**/execution_explorer.spec.ts", "**/recovery.spec.ts"];

export default defineConfig({
  testDir: "./e2e",
  timeout: 60_000,
  expect: {timeout: 10_000},
  // Browser-only this round: the renderer under test is the same on every
  // engine, and the gate runs where chromium is already installed.
  //
  // The specs that run a credential activation share the clinic's one registry,
  // and recovery.spec.ts arms a fault that loses the *next* activation's answer:
  // run beside another activation, the fault can land on the wrong request. They
  // run one at a time in their own project; every other spec runs in parallel.
  projects: [
    {name: "chromium", use: {browserName: "chromium"}, testIgnore: ACTIVATING},
    {name: "chromium-activations", use: {browserName: "chromium"}, testMatch: ACTIVATING, workers: 1},
  ],
  use: {
    baseURL,
    // Lit renders everything in open shadow roots; Playwright's engines pierce
    // those natively, so no special wiring is needed here.
  },
  webServer: {
    // Locally devenv owns the toolchain (bare `mix` picks the wrong
    // Elixir/MIX_HOME), so the default goes through `devenv shell`. This runs
    // in Playwright's process tree, not a developer terminal, so it does not
    // sit on the _build lock the way a long-lived interactive devenv session
    // would. CI has no devenv (its toolchain comes from
    // .github/actions/setup-beam) and sets E2E_SERVER_COMMAND to plain
    // `mix phx.server`; PORT is set below either way.
    command: process.env.E2E_SERVER_COMMAND ?? "devenv shell -- mix phx.server",
    env: {PORT: port},
    url: `${baseURL}/sign-in`,
    cwd: repoRoot,
    // The suite starts the server it tests, so a stray server on the port
    // (another checkout's, an old build) fails the run instead of being
    // tested by mistake. E2E_REUSE=1 reuses one you started by hand while
    // iterating: `devenv shell -- env PORT=4100 mix phx.server`.
    reuseExistingServer: process.env.E2E_REUSE === "1",
    timeout: 180_000,
  },
});
