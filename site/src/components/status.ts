/**
 * How a status looks: its word, its glyph and its colour token.
 *
 * Two vocabularies share the one chip:
 *
 * - delivery, from `docs/roadmap.json`: shipped / partial / planned / open;
 * - control evidence, as `ash_compliance` reports a criterion: owned /
 *   evidenced / unknown.
 *
 * The word is always printed and the glyph's shape differs per status, so no
 * status is told apart by colour alone. Delivery glyphs are circles, control
 * glyphs are squares, so the two vocabularies never read as one scale.
 *
 * What a thing's status *is* never comes from here: callers pass the status
 * read from a ledger. This file only decides how each one is drawn.
 */

export type DeliveryStatus = 'shipped' | 'partial' | 'planned' | 'open';
export type ControlStatus = 'owned' | 'evidenced' | 'unknown';
export type ChipStatus = DeliveryStatus | ControlStatus;

/** Delivery statuses in presentation order. */
export const deliveryStatuses: readonly DeliveryStatus[] = ['shipped', 'partial', 'planned', 'open'];

/** Control statuses in presentation order. */
export const controlStatuses: readonly ControlStatus[] = ['evidenced', 'owned', 'unknown'];

export const statusLabel: Record<ChipStatus, string> = {
  shipped: 'Shipped',
  partial: 'Partial',
  planned: 'Planned',
  open: 'Open',
  owned: 'Owned',
  evidenced: 'Evidenced',
  unknown: 'Unknown',
};

/** The CSS colour for a status, a token from `styles/tokens.css`. */
export const statusColor: Record<ChipStatus, string> = {
  shipped: 'var(--ae-status-shipped)',
  partial: 'var(--ae-status-partial)',
  planned: 'var(--ae-status-planned)',
  open: 'var(--ae-status-open)',
  owned: 'var(--ae-status-owned)',
  evidenced: 'var(--ae-status-evidenced)',
  unknown: 'var(--ae-status-unknown)',
};
