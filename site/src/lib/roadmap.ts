/**
 * Typed access to `docs/roadmap.json` — the single source of truth for every
 * status claim in the repository. README.md, docs/QUESTIONS.md, docs/ROADMAP.md
 * and this site all render from it, so a status can only be wrong here by being
 * wrong everywhere, which is the point.
 *
 * The import reaches out of `site/` into the repo root on purpose: copying the
 * file would create a second truth.
 */

import roadmapJson from '../../../docs/roadmap.json';

export type Status = 'shipped' | 'partial' | 'planned' | 'open';

export interface Section {
  /** e.g. `identity` — matches `Question.section`. */
  id: string;
  title: string;
}

export interface Question {
  /** e.g. `q1`. */
  id: string;
  /** Section id; see `sections`. */
  section: string;
  question: string;
  answer: string;
  status: Status;
  /** Repo-relative path to the test or module that proves the claim, if any. */
  proof?: string;
  /** Four-digit ADR number, e.g. `"0009"`. */
  adr?: string;
  /** Id of the roadmap item that would close this question. */
  item?: string;
}

export interface Item {
  /** e.g. `ingestion` — matches `Question.item`. */
  id: string;
  title: string;
  /** 1 is the most urgent. */
  priority: number;
  /** The decision, in a few words. */
  choice: string;
  /** Four-digit ADR number, e.g. `"0010"`. */
  adr?: string;
  status: Status;
  /** What the work actually is. */
  effort: string;
  /** Whether it clears this platform's authorization/audit bar, and why. */
  bar?: string;
}

interface RoadmapJson {
  $comment?: unknown;
  sections: Section[];
  questions: Question[];
  items: Item[];
}

// `$comment` is documentation for humans editing the JSON; it is not data.
const data = roadmapJson as unknown as RoadmapJson;

export const sections: readonly Section[] = data.sections;
export const questions: readonly Question[] = data.questions;
export const items: readonly Item[] = data.items;

/** All four statuses in the order they should be presented. */
export const statuses: readonly Status[] = ['shipped', 'partial', 'planned', 'open'];

/**
 * Presentation for a status pill. The `dark:` utilities work because
 * `global.css` redefines the `dark:` variant to follow `data-theme`, which is
 * the attribute Starlight sets.
 */
export const statusMeta: Record<Status, { label: string; icon: string; classes: string }> = {
  shipped: {
    label: 'Shipped',
    icon: '✅',
    classes:
      'bg-emerald-50 text-emerald-800 ring-1 ring-inset ring-emerald-600/20 ' +
      'dark:bg-emerald-500/10 dark:text-emerald-300 dark:ring-emerald-400/25',
  },
  partial: {
    label: 'Partial',
    icon: '🟡',
    classes:
      'bg-amber-50 text-amber-800 ring-1 ring-inset ring-amber-600/20 ' +
      'dark:bg-amber-500/10 dark:text-amber-300 dark:ring-amber-400/25',
  },
  planned: {
    label: 'Planned',
    icon: '🔵',
    classes:
      'bg-sky-50 text-sky-800 ring-1 ring-inset ring-sky-600/20 ' +
      'dark:bg-sky-500/10 dark:text-sky-300 dark:ring-sky-400/25',
  },
  open: {
    label: 'Open',
    icon: '⚪',
    classes:
      'bg-zinc-100 text-zinc-700 ring-1 ring-inset ring-zinc-500/20 ' +
      'dark:bg-zinc-400/10 dark:text-zinc-300 dark:ring-zinc-400/25',
  },
};

export interface Counts {
  shipped: number;
  partial: number;
  planned: number;
  open: number;
  total: number;
}

/**
 * Counts across the checklist questions — the numbers the landing page claims.
 * Pass `items` to count the roadmap items instead.
 */
export function counts(source: readonly { status: Status }[] = questions): Counts {
  const out: Counts = { shipped: 0, partial: 0, planned: 0, open: 0, total: 0 };
  for (const row of source) {
    if (row.status in out) out[row.status] += 1;
    out.total += 1;
  }
  return out;
}

/** Questions belonging to a section, in file order. */
export function questionsInSection(sectionId: string): Question[] {
  return questions.filter((q) => q.section === sectionId);
}

/** Roadmap items grouped by priority, ascending. */
export function itemsByPriority(): { priority: number; items: Item[] }[] {
  const groups = new Map<number, Item[]>();
  for (const item of items) {
    const bucket = groups.get(item.priority) ?? [];
    bucket.push(item);
    groups.set(item.priority, bucket);
  }
  return [...groups.entries()]
    .sort(([a], [b]) => a - b)
    .map(([priority, group]) => ({ priority, items: group }));
}

// ---------------------------------------------------------------------------
// Links
// ---------------------------------------------------------------------------

/**
 * Prefix an internal path with the deployment base (`/ash_enterprise`).
 *
 * Every internal href on this site must go through this — GitHub Pages serves
 * the site from a subpath, so a hardcoded `/roadmap` 404s in production while
 * working perfectly in `astro dev`.
 *
 *   withBase('/roadmap')  // -> '/ash_enterprise/roadmap'
 *   withBase()            // -> '/ash_enterprise/'
 */
export function withBase(path = '/'): string {
  const base = (import.meta.env.BASE_URL ?? '/').replace(/\/+$/, '');
  const rest = String(path).replace(/^\/+/, '');
  return rest ? `${base}/${rest}` : `${base}/`;
}

/**
 * The ADR markdown filenames, discovered at build time so the slug never has to
 * be duplicated here. `import.meta.glob` (rather than `node:fs`) keeps this
 * module importable from a client-side script.
 */
const adrFiles = import.meta.glob('../../../docs/adr/[0-9]*.md', {
  query: '?raw',
  import: 'default',
});

const adrSlugByNumber: Map<string, string> = new Map(
  Object.keys(adrFiles).map((filePath) => {
    const slug = filePath.split('/').pop()!.replace(/\.md$/, '');
    return [slug.slice(0, 4), slug];
  }),
);

/**
 * The site route for an ADR number, e.g. `adrHref('0009')` ->
 * `/ash_enterprise/docs/adr/0009-strangler-and-bpmn-are-first-party/`.
 *
 * Returns `null` when no ADR with that number exists, so a caller can render
 * plain text rather than a link that 404s. (`roadmap.json` has referenced an
 * ADR before the file landed.)
 */
export function adrHref(adr: string | undefined | null): string | null {
  if (!adr) return null;
  const slug = adrSlugByNumber.get(String(adr).padStart(4, '0'));
  return slug ? withBase(`/docs/adr/${slug}/`) : null;
}

/** Every ADR number that has a page, for sanity checks. */
export const knownAdrNumbers: readonly string[] = [...adrSlugByNumber.keys()].sort();

/** GitHub blob URL for a repo-relative path — used for `proof` links. */
export function repoHref(repoRelativePath: string): string {
  return `https://github.com/lukegalea/ash_enterprise/blob/main/${repoRelativePath.replace(/^\/+/, '')}`;
}
