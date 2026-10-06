<!-- Draft reply for a2ui-project/a2ui#2753, to nan-yu's 2026-09-25 comment. Not posted. -->

Thanks @nan-yu. I've ported the fix to `typescript/web_core/src/resolution/generic-binder.ts` and rebased the branch onto current `main`, so there are no conflicts now. The branch was force-pushed and is now a single commit.

The new resolution code had been restructured (ref-based classification, the shared unwrap chain), so I rewrote the fix to fit it instead of carrying over the old diff:

- Small helpers read node kinds from either the zod 3 layout (`_def.typeName`) or the zod 4 layout (`def.type`), normalized to the zod 3 names the scraper already compares. They also read object shapes, array elements and zod 4 `pipe` inputs from either layout.
- `unwrapZodSchema` and `getRefDefName` now share one unwrap step instead of two copies of the wrapper chain.
- A schema node with neither layout throws an error naming the property path, e.g. `"(root).outer.items[]"`. Before, it fell back to STATIC without any error.
- The `childRefKindOf` guard from the original PR is no longer needed, because `main` already has it.

The tests use the `zod/v4` subpath of zod 3.25 to cover zod-4-built objects, wrappers, arrays, checkables and the action, dynamic and child-list unions. There's also a zod 3 regression case and a check on the error path. Three of the new tests fail on `main` without the change. I also added a line to the web_core CHANGELOG under Unreleased.

`yarn build`, `yarn test` (841 passing) and `yarn lint` (no errors) all pass in `typescript/web_core`, and the React renderer's unit tests pass. I couldn't run the Karma browser suites for Lit and React locally, so I'm relying on CI for those.
