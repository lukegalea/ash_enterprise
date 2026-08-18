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
