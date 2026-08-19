// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';

// The site is published to GitHub Pages at https://lukegalea.github.io/ash_enterprise.
// `base` therefore prefixes every route. Never hardcode an internal href: use
// `import.meta.env.BASE_URL` (or the `withBase` helper in `src/lib/roadmap.ts`).
export default defineConfig({
  site: 'https://lukegalea.github.io',
  base: '/ash_enterprise',
  output: 'static',
  image: { responsiveStyles: true },
  integrations: [
    starlight({
      title: 'Ash Enterprise',
      description:
        'A reference Ash/Phoenix enterprise application template: the manifesto, the decision records and the plans.',
      // We own `src/pages/*`, including the landing page at `/`. Starlight would
      // otherwise inject its own 404 route and collide with ours.
      disable404Route: true,
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
        {
          label: 'Start here',
          items: [
            { label: 'Documentation', link: '/docs/' },
            { label: 'The enterprise checklist', link: '/docs/questions/' },
            { label: 'Control map', link: '/docs/compliance/' },
            { label: 'Roadmap', link: '/docs/roadmap/' },
            { label: 'Handoff notes', link: '/docs/handoff/' },
          ],
        },
        // Starlight 0.39 removed `label` on an `autogenerate` group: the label
        // now belongs to the group, and `autogenerate` is one of its items.
        { label: 'Manifesto', items: [{ autogenerate: { directory: 'docs/manifesto' } }] },
        { label: 'Decision records', items: [{ autogenerate: { directory: 'docs/adr' } }] },
        { label: 'Plans', items: [{ autogenerate: { directory: 'docs/plans' } }] },
      ],
    }),
    mdx(),
    sitemap(),
  ],
  vite: {
    plugins: [tailwindcss()],
  },
});
