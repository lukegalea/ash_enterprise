# Time travel: surfaces read as of an instant

Ash temporal resources keep every version of a record and read "as of" one
instant. AshA2ui reads a whole surface at one instant, so a page can show
what the data looked like then.

## Reading a surface at an instant

- Pass `as_of: datetime` to `AshA2ui.Info.build_surface/2` or
  `build_data_model/2`. Every read the build makes uses it: tables, option
  lists, contexts, details and section sources. A diagram source receives
  it as `context.as_of`.
- On a temporal resource the read returns the version valid at the
  instant. On any other resource `as_of` only anchors `now()`, so it is
  safe to pass to every read of a mixed surface. Records that are not
  temporal still show their current values: say so on the page.
- Pass the same `as_of:` to `AshA2ui.ActionHandler.handle/3`, so that
  searches, sorts, pages and context selections on the pinned surface keep
  reading at the instant.

## A pinned surface is view-only

- A surface built with `as_of` has its row actions, bulk actions and action
  metadata stripped (`AshA2ui.Info.view_only/1`).
- `AshA2ui.ActionHandler` refuses every action that writes, or opens a
  form that would, when `as_of` is set (`READ_ONLY_AS_OF`).
- The reason is that an action clicked on a historical row would run
  against the live record. It would change the present while the reader
  looks at the past. Do not work around it. Offer "Return to now" instead.

## The URL: `?as_of=`

- `AshA2ui.AsOf.parse/1` accepts ISO 8601 with an offset (shifted to UTC,
  microseconds kept), a `datetime-local` value (read as UTC) or a bare date
  (start of that day, UTC). Anything else means now, so a stale link shows
  the present rather than failing.
- `AshA2ui.AsOf.to_param/1` writes ISO 8601 in UTC and keeps microseconds.
  Link to the exact instant a change happened to show the state just after
  it: a temporal version is valid from its lower bound.
- `AshA2ui.AsOf.put_param/2` sets or removes `as_of` on a path and keeps
  every other parameter.

## LiveRenderer

- `use AshA2ui.LiveRenderer, time_travel: true` reads `?as_of=` on mount,
  builds the surface at that instant and assigns it as `:ash_a2ui_as_of`.
- When `?as_of=` changes, the LiveView navigates to the new URL, which
  rebuilds the surface. A pinned surface and a live one have different
  controls, so a data-model refresh is not enough.

## The scrubber

`AshA2ui.TimeScrubber.scrubber/1` is a Phoenix function component: a range
input over a span, the span's marks (moments worth landing on, such as a
merge), a "Return to now" link and a status readout.

- The host owns the data: the span, the marks and a `path` function from an
  instant (`nil` for now) to a URL.
- The range input posts its position to the host's `event`. Resolve it with
  `AshA2ui.TimeScrubber.instant/4` against the host's own span, then
  `push_patch` to `path`. The client never names an instant directly.
- A position within one step of a mark resolves to the mark's instant.
- Every mark is also a patch link, on the track and in the list of moments.
- Load the page's data in `handle_params/3`, never in `mount/3`.

## Authorization

- An as-of read goes through the same policies as any read. A reader who
  cannot read a record now cannot read its past either.
- Ash checks the actor struct as it was loaded, not as of the instant.
  When the actor itself is temporal, load it as of the same instant before
  building the surface.
