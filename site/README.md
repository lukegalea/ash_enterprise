# site/

The project site: an Astro build that pairs a hand-written landing page with the repository's own
`docs/` tree rendered through [Starlight](https://starlight.astro.build). Published to GitHub Pages at
<https://lukegalea.github.io/ash_enterprise> by `.github/workflows/deploy-site.yml`.

It is a **separate npm project**. It has nothing to do with `assets/`, the Phoenix asset pipeline, or
`devenv`. Node >= 22.12 (Astro 7 requires it); `devenv.nix` already provides `nodejs_22`.

```bash
cd site
npm ci          # or npm install on first run
npm run dev     # syncs docs, then serves at http://localhost:4321/ash_enterprise
npm run build   # syncs docs, then builds to dist/
npm run preview # serve dist/
npm run check   # astro check (TypeScript + template diagnostics)
```

## The base path rule

The site is served from a **subpath**, `/ash_enterprise`. Astro handles this for asset URLs; it does
**not** rewrite hrefs you write by hand. A hardcoded `href="/roadmap"` works perfectly in `astro dev`
and 404s in production, which is the worst possible failure shape.

So every internal link goes through the base:

```astro
---
import { withBase } from '../lib/roadmap';
---
<a href={withBase('/roadmap/')}>Roadmap</a>   <!-- /ash_enterprise/roadmap/ -->
<a href={withBase('/docs/')}>Docs</a>          <!-- /ash_enterprise/docs/ -->
```

`withBase` is a thin wrapper over `import.meta.env.BASE_URL`; use that directly if you prefer, but do
not write a bare `/…`. Links *inside* the docs are handled for you — `scripts/sync-docs.mjs` rewrites
them during the sync and fails the build on a dead one.

## Screenshots and images go in `src/assets/`, never `public/`

Anything under `public/` is copied byte-for-byte to the output root. That means two things:

1. **No base prefix.** You have to remember to write `/ash_enterprise/…` yourself, and one forgotten
   prefix is a broken image in production only.
2. **No optimization.** No resizing, no `webp`/`avif`, no width/height attributes, no `srcset` — a
   2 MB PNG ships as a 2 MB PNG.

Files under `src/assets/` get both, via `<Image />` / `<Picture />` from `astro:assets`:

```astro
---
import { Image } from 'astro:assets';
import shot from '../assets/screenshots/admin-dashboard.png';
---
<Image src={shot} alt="The generated admin dashboard" />
```

`public/` is for files that must keep an exact name at an exact path: `robots.txt`, `.nojekyll`.

## `src/content/docs/` is generated — do not edit, do not commit

`npm run sync` (which `prebuild` runs for you) executes `scripts/sync-docs.mjs`, which copies the
repo-root `docs/` tree into `src/content/docs/docs/` and, on the way:

- injects Starlight frontmatter — `title` from the first `#` heading (removed from the body so it is
  not rendered twice), `description` from the first blockquote or paragraph, and `sidebar.order` from
  a numeric filename prefix (`00-index.md`, `0008-….md`);
- rewrites relative links. `03-authorization-is-data.md` and `../adr/0008-….md` are correct on GitHub
  and wrong here, so they become site routes. Links to non-markdown files (`lib/…ex`,
  `docs/roadmap.json`) become GitHub blob URLs, since the site has no page for them;
- generates a landing page at `/docs/`, and a directory index for any synced directory whose source
  has no `README.md`;
- skips the three raw research transcripts at the root of `docs/` (`AshStrangler.md`, `BPMN.md`, and
  the Strangler Fig one). They are superseded, and one is 1.2 MB;
- **exits non-zero if it rewrote a link to a page that does not exist.** A dead link in generated docs
  is worse than a missing page, so this fails the build rather than shipping it.

The directory is gitignored. To change a doc, change it in `docs/` — that tree is the source of truth,
and it has to keep reading correctly on GitHub too.

The doubled path (`src/content/docs/docs/**`) is not a typo. Starlight has no `base` or `docsRoot`
option: its content collection root *is* the site root, so serving the docs at `/docs/*` means the
files must sit one directory deeper.

## Dark mode

Starlight owns the theme: it stamps `data-theme="light"` or `data-theme="dark"` on `<html>` and
persists the choice to the localStorage key `starlight-theme`. `src/layouts/Base.astro` — the shell for
everything under `src/pages/` — deliberately uses **the same attribute and the same key**, with a
blocking inline script in `<head>` so there is no flash before first paint.

Do not introduce a `.dark` class scheme. If the landing page and the docs disagree about how the theme
is stored, toggling on one and navigating to the other lands the reader in the wrong theme.

Two consequences for anything you write:

- Colours come from tokens in `src/styles/global.css` (`bg-bg`, `bg-surface`, `text-fg`, `text-muted`,
  `border-line`, `text-brand`, …). They are declared on `:root`, redefined under
  `:root[data-theme="dark"]`, and again under `@media (prefers-color-scheme: dark)` guarded as
  `:root:not([data-theme="light"])` so the system default works before anyone chooses.
- Tailwind's `dark:` variant is redefined to follow `data-theme` rather than `prefers-color-scheme`
  (`@custom-variant dark` in `global.css`). `dark:bg-emerald-500/10` therefore agrees with the tokens.

## Stack notes

- **Tailwind 4 via `@tailwindcss/vite`**, not `@astrojs/tailwind`. The latter is a Tailwind 3 wrapper,
  unmaintained since March 2025, and will mis-compile against Tailwind 4.
- `global.css` is imported by `Base.astro` only. It is deliberately **not** passed to Starlight as
  `customCss`: Tailwind's preflight and Starlight's own stylesheet would fight over cascade layers, and
  the docs already have a coherent theme. Tailwind styles the marketing pages; Starlight styles the
  docs; the tokens above keep them looking like one site.

## Deployment

`.github/workflows/deploy-site.yml` builds on pushes to `main` that touch `site/`, `docs/`, `README.md`
or the workflow itself, and on manual dispatch. It uses `withastro/action@v6` (which builds and uploads
the Pages artifact) followed by `actions/deploy-pages@v4`.

**One manual step, once:** in the repository's *Settings → Pages*, set **Source** to **GitHub Actions**.
Until that is done the workflow succeeds and deploys nothing.
