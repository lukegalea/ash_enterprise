# Rules for working with AshJourneys

- A journey's steps reference declared symbols, such as surface ids, Ash actions and A2UI row-action ids. Never write a CSS selector or a URL in a journey.
- Narration (`say`, `note`, `title`, `goal`, `outcome`) is authored prose held as gettext msgids. Never generate it from the steps.
- Documentation, help and agent answers read only approved runs (`priv/journeys/`). Never render from a declaration or a raw run.
- A run that passed only after a retry is flaky. It is never approved and never counts as evidence.
- This package never runs a browser and never records evidence itself. Hosts implement the evidence and figure-store behaviours.
- Every step has narration: at least one `say`. A `note` is an aside, not narration.
- Interpolate labels the application renders with `ui/1` (`ui(:surface_id)`, `ui({:row_action, id})`), never by writing the label into the msgid. Each `%{name}` placeholder needs exactly one binding.
- Row-action ids are the `AshA2ui.Manifest` ids (`"<table>.<action>"`) of the surface the step's persona has open. `open` that surface first, in this step or an earlier one by the same persona.
- Declare `confirm: true` on a row action that asks for confirmation, and only then frame `:dialog`. `AshJourneys.Preflight.check/3` compares the declaration with the surface as the run renders it.
- Pin displayed seed timestamps with `world clock:` and `timestamps:`. Mask only what cannot be pinned (request-time labels), and give every mask a fixed width: `{:as_of, width: "6rem"}`.
- `metadata` is opaque to this package. Put control ids and other host data there; nothing here reads it.
- A changed declaration has a new IR hash (`AshJourneys.Info.hash/2`), so its approved runs no longer prove it.
- Approve figures only with `mix ash_journeys.approve <run-id>`, after reviewing `mix ash_journeys.impact <run-id>`. Never copy files into `priv/journeys/` or edit `journeys.lock.json` by hand, except to move the pinned browser build or the tolerance on purpose.
- A runner records every step it declares, in order, with its real status and attempts, and leaves unmeasured values `nil`. It never fills in a value it did not measure: `approve` refuses unmeasured steps and figures.
- Record `raster_sha256` with `AshJourneys.Raster.hash/1` over the decoded figure, so the runner and `approve` agree on what a raster hash is.
- Put `mix ash_journeys.lock --check` in the static checks. It fails only when a declaration is newer than its approved run.
- Pass `gettext: MyApp.Gettext` to `use AshJourneys.Journeys`. Put `mix ash_journeys.gettext.extract --check-up-to-date` in the static checks, and translate `journeys.pot` with `mix gettext.merge`.
- Publish pages with `mix ash_journeys.export`, which reads only approved runs. A runner paints masked regions `AshJourneys.Export.capture_mask_color/0` (magenta, Playwright's default), so published pages can show them neutral.
