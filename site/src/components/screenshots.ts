/**
 * The screenshot registry.
 *
 * Captures land at different times — some are produced by a separate run
 * against the live application — so a page cannot assume any particular file
 * exists. A direct `import` of a missing image is a hard build failure, which
 * makes `import.meta.glob` the only safe way to reference one.
 *
 * This is the single place that glob is written. `ScreenshotFigure.astro`
 * renders through it, and a page that needs to change its *layout* depending on
 * what landed asks `hasScreenshot/1` first.
 */

const modules = import.meta.glob<{ default: ImageMetadata }>('../assets/screenshots/*.png', {
  eager: true,
});

/** Metadata for a capture, or `undefined` when it was not taken. */
export function screenshot(name: string): ImageMetadata | undefined {
  return modules[`../assets/screenshots/${name}`]?.default;
}

/** Whether a capture is present in this build. */
export function hasScreenshot(name: string): boolean {
  return Boolean(screenshot(name));
}

/** Whether *any* of these captures is present — for optional figure groups. */
export function hasAnyScreenshot(...names: string[]): boolean {
  return names.some(hasScreenshot);
}

/**
 * Animated captures, kept in a separate glob and deliberately NOT run through
 * `astro:assets`.
 *
 * `<Image>` hands the file to sharp, which re-encodes it and keeps only the
 * first frame — so an animation processed that way silently becomes a
 * screenshot. These are emitted as-is and referenced with a plain `<img>`;
 * `AnimationFigure.astro` is the only thing that should read this.
 *
 * `query: '?url'` asks the bundler for the emitted path rather than metadata,
 * because that path is all a raw `<img>` needs.
 */
const animations = import.meta.glob<{ default: string }>('../assets/screenshots/*.gif', {
  eager: true,
  query: '?url',
  import: 'default',
});

/** The emitted URL for an animated capture, or `undefined` when it was not taken. */
export function animation(name: string): string | undefined {
  return animations[`../assets/screenshots/${name}`] as unknown as string | undefined;
}

/** Whether an animated capture is present in this build. */
export function hasAnimation(name: string): boolean {
  return Boolean(animation(name));
}
