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

export default defineConfig({
  testDir: "./e2e",
  timeout: 60_000,
  expect: {timeout: 10_000},
  // Browser-only this round: the renderer under test is the same on every
  // engine, and the gate runs where chromium is already installed.
  projects: [{name: "chromium", use: {browserName: "chromium"}}],
  use: {
    baseURL,
    // Lit renders everything in open shadow roots; Playwright's engines pierce
    // those natively, so no special wiring is needed here.
  },
  webServer: {
    // devenv owns the toolchain (bare `mix` picks the wrong Elixir/MIX_HOME),
    // so the server must go through `devenv shell`. This runs in Playwright's
    // process tree, not a developer terminal, so it does not sit on the
    // _build lock the way a long-lived interactive devenv session would. An
    // already-running server is reused -- start one by hand with
    // `devenv shell -- env PORT=4100 mix phx.server` when iterating.
    command: `devenv shell -- env PORT=${port} mix phx.server`,
    url: `${baseURL}/sign-in`,
    cwd: repoRoot,
    reuseExistingServer: true,
    timeout: 180_000,
  },
});
