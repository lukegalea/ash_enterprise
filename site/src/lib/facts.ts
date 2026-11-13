/**
 * Typed, build-time access to the facts and code the site shows. Pages import
 * from here instead of typing a count, a list or a code sample.
 *
 * Sources:
 *   - `docs/packages.json` and `docs/failures.json`, imported directly;
 *   - `src/data/generated/facts.json` and `snippets.json`, which
 *     `scripts/site-data.mjs` writes before every build and dev server
 *     (`npm run data`) from docs/adr, lib/, docs/routes.json and the ledgers.
 *
 * Every number here is derived. When one looks wrong, fix the source, not the
 * page. For roadmap rows, controls and statuses see `./roadmap.ts`.
 */

import packagesJson from '../../../docs/packages.json';
import failuresJson from '../../../docs/failures.json';
import factsJson from '../data/generated/facts.json';
import snippetsJson from '../data/generated/snippets.json';
import { withBase } from './roadmap';

// ---------------------------------------------------------------------------
// Packages
// ---------------------------------------------------------------------------

/** How a package's maturity was derived; see the `$comment` in docs/packages.json. */
export type Maturity = 'used-and-tested-here' | 'wired-not-tested-here' | 'tooling';

export interface Package {
  name: string;
  /** Top-level module namespace, e.g. `AshBpmn`. */
  module: string;
  repo: string;
  /** One line: what the package is. */
  purpose: string;
  /** What this application uses it for. */
  used_for: string;
  /** Four-digit ADR number, or null. */
  adr: string | null;
  declared: 'direct' | 'transitive' | 'path';
  /** `['dev', 'test']` for tooling, else null. */
  only: string[] | null;
  /** The commit mix.lock pins; null for the path package. */
  ref: string | null;
  /** The package's version at `ref`. */
  version: string;
  /** What the package's own README says about its status, or null. */
  stated_status: string | null;
  maturity: Maturity;
  /** Declared by battery/mix.exs, so CI's cross-substrate battery exercises it. */
  battery: boolean;
  /** Always starts with "git only". */
  distribution: string;
  /** Packages it declares that matter to a reader (first-party, forks, Ash). */
  builds_on: string[];
  /** "free", or "taken: ..." naming the unrelated Hex package. */
  hex_name: string;
  /** Its path to a Hex release, from docs/BLEEDING-EDGE.md. */
  hex_path: string;
  /** What you would carry by keeping it. */
  carry: string;
}

export interface Fork {
  name: string;
  upstream: string;
  upstream_hex: string;
  fork: string;
  branch: string | null;
  ref: string;
  declared: 'direct' | 'transitive';
  override: boolean;
  adds: string;
  path_back: string;
}

export interface Override {
  name: string;
  requirement: string;
  reason: string;
  path_back: string;
}

export interface ToolingFork {
  name: string;
  fork: string;
  branch: string;
  note: string;
}

interface PackagesJson {
  reviewed: string;
  hex_checked: string;
  packages: Package[];
  forks: Fork[];
  overrides: Override[];
  tooling_forks: ToolingFork[];
}

const packagesData = packagesJson as unknown as PackagesJson;

/** First-party packages, in file order. */
export const packages: readonly Package[] = packagesData.packages;
/** Forks of other people's packages the build carries (docs/BLEEDING-EDGE.md §1). */
export const forks: readonly Fork[] = packagesData.forks;
/** `override: true` on a Hex package, with its reason. */
export const overrides: readonly Override[] = packagesData.overrides;
/** Forks used only by developer tooling, not by the build. */
export const toolingForks: readonly ToolingFork[] = packagesData.tooling_forks;
/** The date the hex.pm name check was made. */
export const hexChecked: string = packagesData.hex_checked;

export function packageByName(name: string): Package | undefined {
  return packages.find((p) => p.name === name);
}

/** GitHub URL of a package at the commit mix.lock pins (the repo URL for the path package). */
export function pinnedHref(pkg: Package): string {
  return pkg.ref ? `${pkg.repo}/tree/${pkg.ref}` : pkg.repo;
}

// ---------------------------------------------------------------------------
// Generated facts
// ---------------------------------------------------------------------------

export type AdrStatus = 'accepted' | 'proposed' | 'superseded';

export interface Adr {
  /** e.g. `"0009"`. */
  number: string;
  /** Filename without `.md`; the docs route is `/docs/adr/<slug>/`. */
  slug: string;
  title: string;
  status: AdrStatus;
  /** The whole status line, e.g. "accepted, not built (2026-09-28)". */
  statusText: string;
}

export interface Route {
  verb: string;
  path: string;
  kind: 'live' | 'controller' | 'forward';
  module: string;
  action: string | null;
}

export interface Facts {
  packages: {
    firstParty: number;
    /** Declared in mix.exs (or the path package) and shipped in a release: the home page's count. */
    runtimeDirect: number;
    runtime: number;
    transitive: number;
    tooling: number;
    /** Packages CI's battery exercises together. */
    battery: number;
    /** Package names whose Hex name belongs to an unrelated project. */
    hexNameTaken: string[];
    byMaturity: Record<Maturity, number>;
    forks: number;
    overrides: number;
  };
  adrs: { total: number; byStatus: Record<AdrStatus, number>; list: Adr[] };
  /**
   * Modules in lib/ that declare `use AshEnterprise.Platform.Resource` at module
   * level. A floor: resources built through a wrapping macro are not counted.
   * Say "N resources declare the platform base", not "N resources".
   */
  resources: { declaredOnBase: number; modules: string[] };
  domains: { total: number; modules: string[] };
  routes: {
    total: number;
    byKind: Record<Route['kind'], number>;
    /** LiveView screens at /app and under it. */
    appScreens: number;
    list: Route[];
  };
  roadmap: {
    questions: Record<'shipped' | 'partial' | 'planned' | 'open' | 'total', number>;
    items: Record<'shipped' | 'partial' | 'planned' | 'open' | 'total', number>;
    sections: number;
  };
  controls: {
    frameworks: number;
    controls: number;
    criteria: number;
    criteriaByClass: Record<string, number>;
    criteriaWithEvidenceProducer: number;
  };
  capabilities: {
    total: number;
    byStatus: Record<'existing' | 'partial' | 'missing' | 'refused', number>;
    areas: number;
  };
  failures: { total: number; seeded: number };
  /** `*_test.exs` files in the main suite (battery/ and telemetry/ excluded). */
  tests: { files: number };
}

export const facts: Facts = factsJson as unknown as Facts;

/** ADRs in number order. */
export const adrs: readonly Adr[] = facts.adrs.list;

export function adrsByStatus(status: AdrStatus): Adr[] {
  return adrs.filter((a) => a.status === status);
}

/** The site route of an ADR page. */
export function adrPageHref(adr: Adr): string {
  return withBase(`/docs/adr/${adr.slug}/`);
}

/** Routes the application serves (from the router, dev-only routes excluded), by path. */
export const routes: readonly Route[] = facts.routes.list;

/** True when the router serves this exact path, e.g. `hasRoute('/app/recovery/:id')`. */
export function hasRoute(path: string): boolean {
  return routes.some((r) => r.path === path);
}

// ---------------------------------------------------------------------------
// Failures (the credentialing tour's F1 to F12)
// ---------------------------------------------------------------------------

export interface Failure {
  /** `F1` to `F12`. */
  id: string;
  title: string;
  /** The tour beat that shows it. */
  beat: number;
  /** DOM id of the beat on the tour page. */
  beat_id: string;
  /** Recorded by `mix ash_enterprise.demo --history`; otherwise made by clicking the beat. */
  seeded: boolean;
  what_happens: string;
  tests: { file: string; test: string }[];
}

interface FailuresJson {
  tour: string;
  walkthrough: string;
  failures: Failure[];
}

const failuresData = failuresJson as unknown as FailuresJson;

export const failures: readonly Failure[] = failuresData.failures;
/** The tour's path in the application, e.g. `/app/showcase/credentialing`. */
export const tourPath: string = failuresData.tour;
/** Repo-relative path of the walkthrough. */
export const walkthroughPath: string = failuresData.walkthrough;

// ---------------------------------------------------------------------------
// Snippets
// ---------------------------------------------------------------------------

export interface Snippet {
  name: string;
  title: string;
  caption: string;
  lang: 'elixir' | 'json' | string;
  /** Repo-relative source file. */
  file: string;
  startLine: number;
  endLine: number;
  /** GitHub blob URL with the line range. */
  href: string;
  /** Dedented source text. */
  code: string;
}

const snippetsData = snippetsJson as unknown as Record<string, Snippet>;

/** Names in src/data/snippets.json. */
export const snippetNames: readonly string[] = Object.keys(snippetsData);

/**
 * A snippet by name. Throws on an unknown name, so a page naming a snippet the
 * manifest does not have fails the build instead of rendering an empty block.
 */
export function snippet(name: string): Snippet {
  const found = snippetsData[name];
  if (!found) throw new Error(`No snippet named "${name}" in src/data/snippets.json`);
  return found;
}

// ---------------------------------------------------------------------------
// Prose
// ---------------------------------------------------------------------------

const WORDS = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten',
  'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen',
  'nineteen', 'twenty',
];

/** A count as a word for prose ("seventeen first-party packages"); above twenty, digits. */
export function numberWord(n: number): string {
  return Number.isInteger(n) && n >= 0 && n < WORDS.length ? WORDS[n] : String(n);
}
