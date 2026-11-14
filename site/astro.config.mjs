// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

/*
 * Decision records, grouped by concern for the docs sidebar. Every ADR in
 * docs/adr/ must be in exactly one group: the build fails on an ADR with no
 * group, a number listed twice, or a number with no file, so a new record is
 * never silently left out of the sidebar.
 */
/** @type {[string, string[]][]} */
const ADR_CONCERNS = [
  ['Data model and tenancy', ['0001', '0003', '0049', '0051', '0053', '0059']],
  ['Authorization and identity', ['0023', '0043', '0052', '0066', '0071']],
  ['Audit, retention and compliance', ['0002', '0020', '0021', '0022', '0024', '0025', '0035', '0037', '0064']],
  ['Processes and decisions', ['0004', '0009', '0015', '0027', '0028', '0029', '0030', '0036', '0062', '0069']],
  [
    'Agents and judgments',
    ['0026', '0038', '0039', '0040', '0041', '0042', '0044', '0045', '0046', '0047', '0048', '0055', '0056', '0057', '0058'],
  ],
  ['Data platform and integration', ['0008', '0010', '0011', '0012', '0013', '0014', '0017', '0019', '0031', '0032', '0054', '0063']],
  ['Surfaces and documents', ['0005', '0006', '0033', '0034', '0050', '0060', '0061', '0067', '0068']],
  ['Engineering and operations', ['0007', '0016', '0018', '0065', '0070']],
];

/*
 * Expressive Code makes a code block that scrolls sideways focusable by giving
 * its <pre> role="region" and tabindex="0", with no name. Two such blocks on a
 * page are two unnamed regions, which axe reports (landmark-unique). This names
 * each one while it is a region, and removes the name again when the block
 * stops scrolling, because a name on a plain <pre> is not allowed either.
 * A markdown table that scrolls sideways (Starlight makes them scroll at phone
 * width) gets tabindex="0" for the same reason: a keyboard user must be able
 * to reach and scroll it.
 */
const CODE_REGION_LABELS = `(() => {
  const sync = () => {
    document.querySelectorAll('.expressive-code pre').forEach((pre, i) => {
      if (pre.getAttribute('role') === 'region') {
        if (!pre.hasAttribute('aria-label')) {
          const title = pre.closest('figure')?.querySelector('figcaption .title')?.textContent?.trim();
          const lang = pre.getAttribute('data-language');
          pre.setAttribute('aria-label', 'Code block ' + (i + 1) + (title ? ': ' + title : lang ? ' (' + lang + ')' : ''));
          pre.dataset.aeLabelled = '';
        }
      } else if ('aeLabelled' in pre.dataset) {
        pre.removeAttribute('aria-label');
        delete pre.dataset.aeLabelled;
      }
    });
  };
  new MutationObserver(sync).observe(document.documentElement, { subtree: true, attributes: true, attributeFilter: ['role'] });
  const tables = () => {
    document.querySelectorAll('.sl-markdown-content table').forEach((table) => {
      if (table.scrollWidth > table.clientWidth + 1) table.setAttribute('tabindex', '0');
      else table.removeAttribute('tabindex');
    });
  };
  addEventListener('DOMContentLoaded', tables);
  addEventListener('resize', tables);
})();`;

function adrSidebar() {
  const dir = fileURLToPath(new URL('../docs/adr/', import.meta.url));
  const files = fs.readdirSync(dir).filter((f) => /^\d{4}-.*\.md$/.test(f)).sort();
  const byNumber = new Map(
    files.map((file) => {
      const firstHeading = fs.readFileSync(dir + file, 'utf8').split('\n').find((l) => l.startsWith('# ')) ?? '';
      const title =
        firstHeading.match(/^#\s+(?:\d+\.\s+)?ADR\s+\d{4}\s*[—:-]\s*(.+)$/)?.[1] ?? file.replace(/\.md$/, '');
      const label = `${file.slice(0, 4)} ${title.replace(/`/g, '')}`;
      return [file.slice(0, 4), { slug: `docs/adr/${file.replace(/\.md$/, '')}`, label }];
    }),
  );

  const seen = new Set();
  const problems = [];
  for (const [, numbers] of ADR_CONCERNS) {
    for (const n of numbers) {
      if (seen.has(n)) problems.push(`ADR ${n} is in two groups`);
      if (!byNumber.has(n)) problems.push(`ADR ${n} has no file in docs/adr/`);
      seen.add(n);
    }
  }
  for (const n of byNumber.keys()) if (!seen.has(n)) problems.push(`ADR ${n} is in no group`);
  if (problems.length) throw new Error(`astro.config.mjs ADR_CONCERNS: ${problems.join('; ')}`);

  return [
    { label: 'All decision records', link: '/docs/adr/' },
    ...ADR_CONCERNS.map(([label, numbers]) => ({
      label,
      collapsed: true,
      items: numbers.map((n) => /** @type {{ slug: string, label: string }} */ (byNumber.get(n))),
    })),
  ];
}

// The site is published to GitHub Pages at https://lukegalea.github.io/ash_enterprise.
// `base` therefore prefixes every route. Never hardcode an internal href: use
// `import.meta.env.BASE_URL` (or the `withBase` helper in `src/lib/roadmap.ts`).
export default defineConfig({
  site: 'https://lukegalea.github.io',
  base: '/ash_enterprise',
  output: 'static',
  // Pages that moved: /vision/ and then /product/ became /platform/, and
  // /controls/ became /proof/. In static output Astro emits a meta-refresh
  // HTML page for each. Astro prefixes `base` on the redirect *source* (the
  // page lands at /ash_enterprise/product/) but NOT on the *destination*, so
  // the base is written into the destination here — otherwise production
  // would redirect to a bare /platform/ that does not exist outside the
  // subpath.
  redirects: {
    '/vision': '/ash_enterprise/platform/',
    '/product': '/ash_enterprise/platform/',
    '/controls': '/ash_enterprise/proof/',
  },
  image: { responsiveStyles: true },
  integrations: [
    starlight({
      title: 'Ash Enterprise',
      description:
        'A reference Ash/Phoenix enterprise application template: the manifesto, the decision records and the plans.',
      // We own `src/pages/*`, including the landing page at `/`. Starlight would
      // otherwise inject its own 404 route and collide with ours.
      disable404Route: true,
      head: [{ tag: 'script', content: CODE_REGION_LABELS }],
      // The docs wear the marketing pages' tokens and type: `starlight.css`
      // maps Starlight's `--sl-*` variables onto `tokens.css`, and the fonts are
      // the same self-hosted @fontsource files `layouts/Base.astro` loads.
      customCss: [
        '@fontsource/newsreader/400.css',
        '@fontsource/geist/400.css',
        '@fontsource/geist/500.css',
        '@fontsource/geist/600.css',
        '@fontsource/ibm-plex-mono/400.css',
        './src/styles/starlight.css',
      ],
      expressiveCode: {
        styleOverrides: {
          borderRadius: '2px',
          codeFontFamily: 'var(--ae-font-mono)',
          uiFontFamily: 'var(--ae-font-sans)',
        },
      },
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/lukegalea/ash_enterprise',
        },
      ],
      // Starlight has no `base`/`docsRoot` option: the content collection root IS
      // the site root. Mounting the docs under `/docs/*` therefore means the files
      // must live at `src/content/docs/docs/**`, which is what `scripts/sync-docs.mjs`
      // generates. The `directory:` values below are relative to `src/content/docs/`.
      sidebar: [
        { label: 'Documentation', link: '/docs/' },
        // Starlight 0.39 removed `label` on an `autogenerate` group: the label
        // now belongs to the group, and `autogenerate` is one of its items.
        { label: 'Manifesto', items: [{ autogenerate: { directory: 'docs/manifesto' } }] },
        {
          label: 'Reference',
          items: [
            { label: 'The enterprise checklist', link: '/docs/questions/' },
            { label: 'Control map', link: '/docs/compliance/' },
            { label: 'Roadmap', link: '/docs/roadmap/' },
            { label: 'Dependencies not on Hex', link: '/docs/bleeding-edge/' },
            { label: 'House style', link: '/docs/house-style/' },
          ],
        },
        { label: 'Decision records', items: adrSidebar() },
        { label: 'Plans', collapsed: true, items: [{ autogenerate: { directory: 'docs/plans' } }] },
      ],
    }),
    mdx(),
    sitemap(),
  ],
  vite: {
    plugins: [tailwindcss()],
  },
});
