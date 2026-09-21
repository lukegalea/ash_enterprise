# ash_compliance usage rules

_Rules for working with the ash_compliance library, for humans and agents
alike._

## The bundle hash is the contract

> **Every finding and evaluation pins the bundle that produced it.**

Never evaluate a tenant's compliance against a bundle you constructed by
hand: compile it, activate it, resolve it through the projector's `:bundle`
MFA. The hash on a finding must be traceable to an active
`PolicyBundle` row — that is the audit trail.

## Rules

1. **The precedence is fixed.** Do not add "just this once" layer jumps,
   caller-supplied rule lists, or inheritance shortcuts. If a layer's
   permissions are wrong for a program, change the design document first and
   `Layer` second.
2. **Waivers are bounded, approved and offset.** Never relax the expiry,
   approver or compensating-control validations. An expired waiver returning
   its rule to the bundle is a feature, not a bug to suppress.
3. **Unknown never becomes compliant.** Do not feed placeholder facts to
   silence `:unknown` findings; fix the fact pipeline or the absence
   semantics.
4. **The finding is the now, the evaluation is the decision.** Never mutate
   `ComplianceEvaluation` rows, never fold them into the projection, never
   skip recording one.
5. **Grain changes are migrations.** The finding grain
   `[organization_id, control_id, subject_type, subject_id]` is the identity
   of every row; changing it invalidates projections and histories. Bump the
   projector name (blue/green) instead of drifting the grain.
6. **No API layer.** The package ships resources and actions. Do not add
   JSON:API/GraphQL surfaces here; the host owns exposure and its policies.
