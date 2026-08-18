/**
 * The prose in `docs/roadmap.json` is written for markdown readers, so it
 * carries `` `code` `` spans and the occasional *emphasis*. The site renders
 * those strings into HTML, which means they have to be escaped first and then
 * re-marked-up — in that order, or a stray `<` in an answer becomes a tag.
 *
 * Deliberately tiny: this handles the three constructs the JSON actually uses
 * (code spans, emphasis, en-dashes are already literal) and nothing else. A
 * markdown library here would be a dependency bought to parse strings we
 * control.
 */

const ESCAPES: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
};

function escapeHtml(text: string): string {
  return text.replace(/[&<>"]/g, (char) => ESCAPES[char]!);
}

/**
 * Escape, then render `` `code` `` as `<code>` and `*emph*` / `_emph_` as
 * `<em>`. Safe to hand to `set:html`.
 */
export function inlineMarkdown(text: string): string {
  return escapeHtml(text)
    .replace(
      /`([^`]+)`/g,
      '<code class="rounded bg-code-bg px-1 py-0.5 font-mono text-[0.85em] text-fg">$1</code>',
    )
    .replace(/(?<![\w*])\*([^*\n]+)\*(?![\w*])/g, '<em>$1</em>')
    .replace(/(?<![\w_])_([^_\n]+)_(?![\w_])/g, '<em>$1</em>');
}

/** Last path segment, for showing a proof link without its whole directory. */
export function basename(path: string): string {
  return path.split('/').pop() ?? path;
}
