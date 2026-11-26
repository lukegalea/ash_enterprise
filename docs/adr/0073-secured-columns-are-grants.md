# ADR 0073 — Secured columns are grants: a column a row grant does not hand over

- **Status:** accepted (2026-11-14), built for reads
- **Date:** 2026-11-14

## Context

Authorization here is `(role, privilege, depth)` data evaluated as a pure union with no deny rules
(`docs/manifesto/03-authorization-is-data.md`). It answers "may this person read this row". Some columns are more
sensitive than the rows that hold them: a credential's licence number, where a reviewer needs to know that a clinician
holds a licence and when it expires, not the number itself.

Until now the only answer was one hand-written field policy, on `Integration.LinkedAccount`, hiding `connection_id`
from every read grant. Nothing on the base resource let a resource say "this column needs more than the row", and
`sensitive?` only redacts a value from logs and the audit trail. Dataverse's answer is column security: a column is
marked secured, and a field security profile, assigned to users or teams, grants read, create or update on it. A
system administrator holds every column.

Ash supports field policies: simple and filter checks per field, the value read as `%Ash.ForbiddenField{}` when no
policy passes, and a filter a client supplied (`Ash.Query.filter_input/2`) rewritten so a forbidden column reads as
`nil`. Once any field policy exists, every field must be covered by one.

## Decision

**A secured column is granted like a row: by a privilege a role holds at a depth.**

1. `AshEnterprise.Platform.Resource` takes `secured_fields: [:field, ...]`. For each field the base writes a field
   policy that authorizes through `{AshEnterprise.Security.Checks.RoleGrant, field: name}`, plus
   `field_policy :* do authorize_if always() end`. No `forbid_if`: a column is reached by a grant or not at all, and
   the grants stay a union.
2. The privilege catalogue (`Platform.Seeder`, rewritten at every boot) writes one `:read` privilege per secured column,
   keyed `"<Resource>#<field>"` and named `prvRead<Entity>.<field>`, with the resource's own legal depths. It is a
   privilege like any other: a role grants it, `ActorContext` precomputes it, and the check reads it without a query.
   The row grant does not include it, and neither does a grant on the column alone include the row.
3. `RoleGrant`'s `field:` option reads the `:read` grant on the column's key whatever action is running (Ash evaluates
   field policies on what a create or update returns too), and builds its depth filter against the row's own columns:
   a column grant at `:local` shows the value on rows in that business unit and hides it on the rest. A system actor
   reaches it as it reaches the row.
4. The Administrator holds every column. The Administrator auto-grant already takes every globally grantable,
   non-operator privilege, at provisioning and at every boot (`PrivilegeSync`), so a new secured column reaches the
   Administrator with no step. This is Dataverse's posture for its administrator.
5. A sweep of "every read privilege" does not take a column. The demo Auditor role reads everything and is not handed
   the columns: a column is secured so that it is granted by name. A column's privilege is reserved or owner-only
   exactly when its resource's are (`Privilege.base_resource_name/1`).
6. A filter that reaches a secured column matches only where the reader may see it. Ash rewrites a client's filter; a
   filter the application builds for a person (a search box, a lookup through a relationship) is trusted as written,
   and would answer "which row has this number" one question at a time. So every authorized read of a platform
   resource rewrites each reference to a secured column, on the resource or across a relationship, to
   `if <visible on this row>, do: column, else: nil` (`Security.Preparations.SecuredFieldRefs`), the same rewrite Ash
   applies to client input, from the precomputed context. Two uses cannot be rewritten that way and are refused with
   an `Ash.Error.Invalid` naming the column, for a reader who does not see it on every row: a sort that reads it
   (directly, or through a calculation or an aggregate), whose order would answer what the field policy withholds, and
   a filter on a calculation or an aggregate that reads it, which the data layer evaluates past the field policy. Keyset
   cursors are signed (`config :ash, :keyset_signing_secret`, derived from `SECRET_KEY_BASE` in a deployment), so a
   cursor a reader wrote to page past a hidden value is refused.

   > **2026-11-20.** A third use is refused the same way: a calculation or an aggregate loaded on the read that reads
   > the column (`Ash.Query.calculate/4`, an aggregate built at run time, one loaded onto records in hand with
   > `Ash.load/3`, or one inside a relationship's load), for a reader who does not see it on every row. The test in the
   > Consequences scans only the calculations and aggregates the application declares; one built by the code that reads
   > returned the value to a reader without the grant. `SecuredFieldRefs` walks a load as it walks a sort, and the
   > refusal names the column.
7. `AshEnterprise.Platform.Verifiers.SecuredFields` refuses a name that is not an attribute, the primary key (Ash shows
   it to everyone), an ownership or tenant column (authorization reads them), a column that is not `sensitive?` (the
   audit log keeps every other changed value, and is read through a row grant), and a resource that also declares
   field policies of its own. `LinkedAccount` keeps its hand-written policy, which is a different rule (visible only through
   two actions), beside this one.
8. Pages show a hidden value as masked text: `Phoenix.HTML.Safe` is implemented for `Ash.ForbiddenField`
   (`AshEnterpriseWeb.HiddenField`), and on the JSON wire it is `null`, as AshJsonApi renders a forbidden field. An
   A2UI surface, which serializes a struct it does not know by inspecting it, shows the inspected struct. Either way a
   form filled from the record holds a stand-in, so an update keeps the stored value when a writer who cannot see the
   column sends back `nil`, a blank or that inspected text (`Security.Changes.KeepHiddenSecuredFields`). `String.Chars`
   is not implemented, so code that builds a key or a request from a hidden value fails instead of using a mask.

   > **2026-11-20.** An A2UI surface no longer shows the inspected struct. Since `ash_a2ui` 2f9a924 it sends a hidden
   > value as `null`, as the JSON wire does, so a cell, a card or a form field there shows it empty, not masked
   > (`AshEnterpriseWeb.HiddenField`). Pages still show the masked text. Until `ash_a2ui` renders a hidden value as
   > masked, a surface over a secured resource does not title its rows by a secured column: the credentialing
   > workspace titles a credential by its clinician.

   > **2026-11-21.** `ash_a2ui` now renders a hidden value as masked text, never empty: the cell, card, badge and
   > detail line show its translated word "Hidden", the record carries the reason at a reserved `_masked/<field>` key,
   > and nothing of the struct reaches the wire. The edit buffers (`/form`, `_edit_<field>`) and CSV exports keep `null`
   > or an empty cell, so a submit never writes the masked word back and `KeepHiddenSecuredFields` is unchanged. The
   > credentials table is tested for it (`SecuredFieldsTest`: a reader without the grant sees the masked number and its
   > reason, a holder sees the number and no mask).


The first secured column is `Credentialing.Credential.number`. The coordinator who records numbers holds it through a
role of its own; the credentialing committee reviews an activation without it.

## Consequences

- **Reads only.** A write to a secured column follows the row's grant. Dataverse also secures create and update per
  column; that is not built, and the ledger's answer for column security stays partial until it is or the scope is
  settled as reads.
- **A governed act sends what it was approved to send.** The registry activation runs as its requester, who may not
  hold the column; it reads the number from the row past the field policy
  (`Credentialing.Changes.ActivateInRegistry`). The column's grant decides who sees a value, not what an approved act
  sends: that is the act's four-eyes approval and the disclosure gate.
- **The column, not every copy of it.** A secured column hides that column. A value copied into another record is that
  record's: a licence document's text, the licence reader's judgment rows and the input of the run that read it carry
  the number, and are read through their own grants. Demo data does not copy the number into a document's title.
- **What the application derives from the column is masked with it.** The base's `field_policy :*` authorizes every
  calculation and aggregate on a resource with secured columns, so a derivation is only as safe as the code that
  computes it. `Credentialing.Findings` reads the credential's number through the reader and masks a finding that
  answers the licence number question (its value and the text of the lines it cites) when the column is hidden, so
  the credential's `document_findings` and the tour show it as hidden where the column is. Ash applies no field
  policy to a column an expression reads, on the resource or across a relationship, so an expression calculation or
  an aggregate (its field or its filter) that reads a secured column anywhere in the application fails a test
  (`secured_fields_test.exs`, "nothing derived reads a secured column"). A module calculation is not scanned: one
  that derives from a secured column reads it through the reader, as `Findings` does.
- **A sort is refused, not rewritten.** A sort on a secured column would order the rows a reader can see by a value
  they cannot read, and a keyset page over it would let them search the values. So it is refused for a reader who
  does not see the column on every row, a grant below `:global` included, and a page that lists such a column does
  not sort by it by default (the credential workspace sorts by expiry). A client's sort across a relationship
  (`sort_input("credential.number")`) is already a sort by `nil` there: Ash's field policy replaces the value.
- **Field policies do not run in the policy bypasses.** The engines reach a secured column through the actor they
  carry, and a system actor through `RoleGrant`'s system branch; FEEL drops a forbidden field from its context
  (ADR 0027), so a process that needs the value reads it as a system actor or not at all.
- Adding a secured column needs no migration: privileges are rows, written at the next boot.
