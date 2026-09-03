# VPM-12 legacy-to-canonical mappings

The resources in `AshEnterprise.Contracts` are the VPM-8 canonical surface. The
compatibility resources are in the `:read_from_legacy` phase and use only typed
`ash_strangler` declarations. `mix ash_strangler.gen.migration` is the sole
source of compatibility views, indexes, `INSTEAD OF` triggers where needed, and
the `pg_notify` bridge; no compatibility SQL is authored in this repository.

The legacy twins are snapshots of the VPM-11 dump. They name the real schemas
(`public.clm_*` and `vendorpm.*`) and are intentionally not migrated by Ash.
The initial mapping pass covers the relations that VPM-11 assigned to canonical
areas:

| Canonical resource | Legacy relation | Mapping decision |
| --- | --- | --- |
| Party | `public.clm_parties` | UUID identity, name, client id, and metadata |
| Party-shaped vendor surface | `vendorpm.vendors` | deterministic UUIDv5 identity and vendor decorations |
| Party-shaped enterprise surface | `vendorpm.enterprises` | deterministic UUIDv5 identity and legal name; feature flags remain configuration |
| ContractingProcess | `vendorpm.rfqs` | deterministic UUIDv5 identity, OCID projection, and timestamp lifecycle |
| PartyRole | `vendorpm.rfq_responses` | response party ids and tri-state interest |
| Contract | `public.clm_contracts` | contract fields and processed/verified/archived lifecycle |
| ContractLine | `vendorpm.quotes` | quote identity, party/RFQ correlation, price, and review signal |
| Commitment | `vendorpm.compliance_documents` | compliance assurance type, status, expiry, and attachment path |
| Amendment | none | greenfield canonical resource; no legacy amendment relation exists |
| Milestone | none | greenfield canonical resource; no legacy milestone relation exists |
| Transaction | none | greenfield canonical resource; VPM-11 found no contract-payment incumbent |

## Non-invertible mappings

These are stated limitations, not guessed inverse SQL. Every read-only mapping
has `read_only?: true` and a `because:` message in the declaration; every
constant or unmapped platform field is explicit.

- `ContractingProcess.ocid` from `rfqs.id` is non-invertible: the OCID is a new
  canonical correlation identity and the legacy RFQ has no OCID column. The
  generated UUID key and OCID must not be parsed back into a legacy integer.
- `ContractingProcess.lifecycle_status` collapses `submitted` and `cancelled`
  timestamps into canonical draft/published/cancelled states. The `collapse`
  declaration supplies a single canonical write shape, but `touch()` means the
  original timestamp cannot be recovered; this remains a stated semi-isomorphism.
- `Contract.lifecycle_status` collapses `processed`, `verified`, and `archived`
  into processing/unverified/active/archived. Multiple legacy boolean/timestamp
  combinations have the same canonical meaning, so the original combination is
  not recoverable; the clause `set:` values are the canonical write-back choice.
- `PartyFromVendor.id` is a deterministic UUIDv5 derived from integer `vendors.id`.
  UUIDv5 is useful for stable reads but cannot itself be written back as a vendor
  primary key without the twin's source integer, so writes use the legacy id
  through the generated key path only.
- `PartyRole.role` and `Commitment.commitment_type` are constants. `rfq_responses`
  and `compliance_documents` contain no canonical role/type discriminator from
  which a different value could be recovered.
- `PartyRole.legacy_rfq_id` and `legacy_party_id`, and the analogous commitment
  ids, remain integer correlation fields. VendorPM has no canonical Party UUID
  foreign key on these relations, so inventing one would not be translatable back.
- `Commitment.attachment` and `PartyRole.additional_insured_document` are paths,
  not Artifact/Document foreign keys. A path cannot be translated into a
  canonical Artifact identity or reverse-resolved to its owner.
- The platform provenance fields on all compatibility resources are unmapped as
  NULL. VendorPM does not record Ash actor ids or import sequence numbers, and
  fabricating provenance would misstate who changed historical rows.

The canonical `Amendment`, `Milestone`, and `Transaction` resources deliberately
have no strangler source yet. Their absence is a schema finding, not a silently
invented mapping: VPM-11 found no amendment/milestone relations and no
contract-payment incumbent. They become mappings only when a real legacy shape
exists to derive and translate.
