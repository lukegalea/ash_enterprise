# ADR 0064 — Production environments are a separate domain from compliance

- **Status:** accepted (2026-11-09); the seam is built in `ash_compliance`, see Known departures
- **Date:** 2026-11-09
- **Related:** ADR 0021 (the control map is generated), ADR 0042 (zones are a data-residency boundary)

## Context

`ash_compliance` ships two Spark extensions. `AshCompliance.Boundary` declares the boundary itself, `environments` and
`resources`, and writes three files: a tfvars file, an assertions file and a snapshot. `AshCompliance.Boundary.Controls`
adds a `controls` section, reads the production declaration, and writes a control map and its own snapshot. Each has its
own transformer, which checks its declaration at compile time and reports every violation together. `mix ash.codegen`
merges the files of every extension on the module. The generated files are compared byte for byte with hand-written
ones in the test fixture.

The code holds two kinds of fact. Some are about what exists and where it runs: environments, the resource inventory,
the tfvars, the assertions. Others are about audit: which criterion a resource and its evidence satisfy. The two have
different lifetimes and different readers. This record fixes the seam before more is built on it.

What is not present: boot assertions, route enumeration, restore tests, and any comparison of declared state with
applied state. The assertions are emitted for a checker. Nothing here consumes them.

## Decision

1. **There are two domains.** Compliance answers: what must be true, and can we show it? Production answers: what exists,
   where does it run, and does reality match what we declared? The test: would a team with no audit still want this? If
   yes, it is production.
2. **Classification.**
   - Production: environment declarations, with their class and data ceiling; resource inventory, managed or referenced;
     checking declared state against applied state; generated infrastructure inputs and assertions; boot assertions;
     enumerating the routes into a production image; restore tests. Each is reported as facts.
   - Compliance: control links from a criterion to a resource and its evidence; the control map; the criteria
     catalogue; evidence freshness; findings and overrides.
3. **Dependency runs one way.** The production side knows nothing about SOC 2, criteria or controls. Compliance reads
   production's facts as evidence. A rule that needs both lives in the control section and reads the production facts,
   never the reverse.
4. **No extraction yet.** The declaration stays in `ash_compliance` as `AshCompliance.Boundary`. The control section is
   the only part that knows about compliance, so extraction is a move and not a rewrite. The declaration has two
   extensions: `AshCompliance.Boundary` (environments and resources) and `AshCompliance.Boundary.Controls` (controls),
   with Controls reading Boundary and never the reverse.
5. **Extract when** a second real host needs it (a reference host in the same programme does not count), or when the
   production side gains behaviour of its own, such as release promotion or restore drills.
6. **Stop condition.** The declaration's output must match hand-written files exactly. If it cannot, keep the files.
   There is nothing to extract.
7. **Declare and verify only.** This is not an infrastructure generator: no HCL writer, no stack, no release runner. The
   real hazards are specific to modules and templates, for example a provider attribute whose change replaces a stateful
   instance. A generic package would not catch them.
8. **The name, when extracted, is `ash_environments`.** It models environments and what is in them. Rejected:
   `ash_deployments`, which implies it runs releases; `ash_production`, which must also describe excluded,
   non-production environments.
9. **Zones stay a data-residency boundary** ([ADR 0042](0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md)).
   An environment may reference a zone by id and does not extend it. The code holds the zone as a string and checks
   only that it is non-blank and has no whitespace.

## Known departures

None remain. The declaration was split into the two extensions in Decision 4 by
[ash_compliance PR 20](https://github.com/lukegalea/ash_compliance/pull/20) (merge `279dc7a`). The environment classes
are `:production` and `:non_production`, and the production side's tfvars keys and schema ids carry no audit name. The
production snapshot holds no controls, and a declaration with only the production extension compiles, validates and
writes its three files. `--check` fails when a removed extension's generated files are still on disk, and a write
removes them. A test scans the production files for audit vocabulary. The modules still live under the `AshCompliance`
namespace, which is Decision 4 and not a departure from it.

## Consequences

- One package carries two concerns until extraction. Contributors must keep the line in Decision 3 by discipline,
  since nothing enforces it.
- Extraction will rename the module names and move the production files' owner; consumers of the generated files move
  with them.
- The production side can be reviewed, tested and versioned without reading anything about audit.
- Environments and resources are validated by their own rule set, separate from the controls rules; a declaration with
  no controls compiles alone and is tested.
- There is no generator to maintain. Hazards that live in a module or template stay with the host that owns it.

## Supersession

Superseding this record requires a new ADR.
