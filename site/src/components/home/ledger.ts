/**
 * What the home page and /platform/ read from the ledgers, in the shape they
 * render: a status for a checklist question or a capability row, the packs in
 * `priv/packs/`, and links to pages that may not be in this build.
 *
 * Nothing here decides a status. A question's status is its row in
 * `docs/roadmap.json`; a capability's is its row in `docs/capabilities.json`.
 * An id that is not in its ledger fails the build, so a page cannot show a chip
 * for a row that was renamed or removed.
 */

import capabilitiesJson from '../../../../docs/capabilities.json';
import { questions, withBase, type Question } from '../../lib/roadmap';
import type { ChipStatus } from '../status';

// ---------------------------------------------------------------------------
// The checklist (docs/roadmap.json)
// ---------------------------------------------------------------------------

export function question(id: string): Question {
  const found = questions.find((q) => q.id === id);
  if (!found) throw new Error(`No question "${id}" in docs/roadmap.json`);
  return found;
}

/** The checklist page, where every question, answer and proof is listed. */
export const checklistHref = withBase('/docs/questions/');

// ---------------------------------------------------------------------------
// The capability inventory (docs/capabilities.json)
// ---------------------------------------------------------------------------

export type CapabilityStatus = 'existing' | 'partial' | 'missing' | 'refused';

export interface Capability {
  id: string;
  area: string;
  capability: string;
  status: CapabilityStatus;
  summary: string;
  gap?: string;
}

const capabilityRows = (capabilitiesJson as unknown as { capabilities: Capability[] }).capabilities;

export function capability(id: string): Capability {
  const found = capabilityRows.find((c) => c.id === id);
  if (!found) throw new Error(`No capability "${id}" in docs/capabilities.json`);
  return found;
}

/**
 * The chip for a capability row. The inventory grades on its own scale, and the
 * chip prints the inventory's own word (`capabilityWord`): Existing, Partial or
 * Missing, never "Shipped", which on the checklist means running in a deployment
 * we operate. Only the glyph and colour are borrowed, the same way /proof/ draws
 * the inventory: `existing` takes the shipped glyph, `partial` the partial one,
 * `missing` the open one. A `refused` row is a decision, not a status, and has
 * no chip: naming one throws.
 */
export function capabilityStatus(id: string): ChipStatus {
  const row = capability(id);
  switch (row.status) {
    case 'existing':
      return 'shipped';
    case 'partial':
      return 'partial';
    case 'missing':
      return 'open';
    default:
      throw new Error(`Capability "${id}" is ${row.status}; show its reason, not a chip`);
  }
}

const CAPABILITY_WORDS: Record<CapabilityStatus, string> = {
  existing: 'Existing',
  partial: 'Partial',
  missing: 'Missing',
  refused: 'Refused',
};

/** The word the capability inventory uses for a row's grade, printed on its chip. */
export function capabilityWord(id: string): string {
  return CAPABILITY_WORDS[capability(id).status];
}

// ---------------------------------------------------------------------------
// Packs (priv/packs/*/pack.json)
// ---------------------------------------------------------------------------

export interface Pack {
  name: string;
  title: string;
  description: string;
  controls: string[];
  processes: { key: string }[];
  recipes: { key: string }[];
  /** Repo-relative path of the pack's manifest. */
  path: string;
}

const packModules = import.meta.glob<{ default: Omit<Pack, 'path'> }>(
  '../../../../priv/packs/*/pack.json',
  { eager: true },
);

/** Every pack the repository ships, by name. */
export const packs: readonly Pack[] = Object.entries(packModules)
  .map(([file, mod]) => ({
    ...mod.default,
    path: file.replace(/^(\.\.\/)+/, ''),
  }))
  .sort((a, b) => a.name.localeCompare(b.name));

// ---------------------------------------------------------------------------
// Pages
// ---------------------------------------------------------------------------

const pageFiles = Object.keys(import.meta.glob('../../pages/**/*.{astro,md,mdx}'));

/**
 * A link to one of this site's pages, or to `fallback` when that page is not in
 * this build. Lets the home page link a sibling page before it lands without
 * shipping a link that 404s.
 */
export function pageHref(route: string, fallback: string): string {
  const name = route.replace(/^\/+|\/+$/g, '');
  const exists = pageFiles.some(
    (f) => f.endsWith(`/pages/${name}.astro`) || f.endsWith(`/pages/${name}/index.astro`),
  );
  return withBase(exists ? route : fallback);
}
