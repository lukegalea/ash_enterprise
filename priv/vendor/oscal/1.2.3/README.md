# OSCAL 1.2.3 assessment-results JSON schema (vendored)

`oscal_assessment-results_schema.json` is NIST's official JSON schema for the OSCAL
assessment-results model, release v1.2.3, copied unchanged from the release asset:

- source: https://github.com/usnistgov/OSCAL/releases/download/v1.2.3/oscal_assessment-results_schema.json
- sha-256: `4034e2032332dbf597e59e0646ec16c2c31df992962490371e91f47b219ff42c`
- licence: `LICENSE.md` beside it, copied from the OSCAL repository at the same tag. The
  work is in the public domain in the United States and dedicated to the public domain
  worldwide under CC0 1.0. NIST asks that it be acknowledged as the source, which this
  file does.

`test/ash_enterprise/audit/package_test.exs` validates the audit package's
`assessment-results.json` (`AshEnterprise.Audit.Package.Oscal`) against it and checks the
file against the pin above.

## How the test reads it

The schema is draft-07. Each definition repeats its own location as its `$id`
(`"$id": "#/definitions/<name>"`), which JSV refuses as an identifier. The test removes an
`$id` only where it equals the definition's own location, which changes nothing it
resolves to, and refuses any other. The file itself is never edited.

## Re-pinning

1. Download the schema and `LICENSE.md` of the new release into a new version directory.
2. Move `@oscal_version` in `AshEnterprise.Audit.Package.Oscal` and the path and pin in the
   test.
3. Run the test, and read the release notes for model changes before accepting it.
