/**
 * The Shiki theme for `Exhibit.astro`: the Atelier dark palette as TextMate
 * scopes. Exhibits are dark in both site themes, so this is one theme, and
 * each colour clears 4.5:1 on `--ae-exhibit` (#151714 and #111310). The hex
 * values repeat the dark tokens in `styles/tokens.css` because Shiki resolves
 * colours at build time and cannot read a CSS variable.
 */
export const exhibitTheme = {
  name: 'atelier-exhibit',
  type: 'dark' as const,
  colors: {
    'editor.background': '#151714',
    'editor.foreground': '#e6e1d3',
  },
  tokenColors: [
    { settings: { foreground: '#e6e1d3', background: '#151714' } },
    { scope: ['comment', 'punctuation.definition.comment'], settings: { foreground: '#9c978a', fontStyle: 'italic' } },
    {
      scope: ['keyword', 'storage', 'keyword.control', 'keyword.operator.word', 'variable.language'],
      settings: { foreground: '#7fa894' },
    },
    { scope: ['string', 'string.quoted', 'string.interpolated'], settings: { foreground: '#c98a5e' } },
    {
      scope: [
        'constant',
        'constant.other.symbol',
        'constant.language',
        'constant.numeric',
        'support.constant',
        'variable.other.constant',
      ],
      settings: { foreground: '#8faac4' },
    },
    { scope: ['entity.name.type', 'entity.name.class', 'support.class', 'entity.name.namespace'], settings: { foreground: '#e8e3d6' } },
    { scope: ['entity.name.function', 'support.function'], settings: { foreground: '#d9c9a3' } },
    { scope: ['constant.language.boolean', 'constant.language.nil'], settings: { foreground: '#e0664a' } },
    { scope: ['punctuation', 'keyword.operator'], settings: { foreground: '#b8b2a3' } },
  ],
};
