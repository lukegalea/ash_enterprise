# Runbook: an organization's approval posture

An organization's approval posture decides which person approves a four-eyes request: publishing an agent, a
governed role assignment, a credentialing decision. It never lets anyone but a person approve, and it never widens
what anyone may do. The rule is `ash_agent`'s (`AshAgent.Approval.Posture`); the decision record is
[ADR 0055's 2026-11-12 amendment](../adr/0055-consequential-acts-are-governed-invocations.md#amendment-2026-11-12--approval-postures).

| Posture | Who approves a four-eyes request | Ends |
|---|---|---|
| `standard` (every organization's default) | Another holder of the approver role, never the requester | Never |
| `small_team` | The requester, if they hold the approver role; any administrator when nobody holds it | When a person raises it |
| `implementation` | The requester confirms it themselves | On its end date, at most 120 days out, when it reads as `standard` |

Changing the posture itself is always four eyes when it is requested through an invocation (`posture_floor?: true`).

## Who may change it

- **Raise it** (towards `standard`, or an `implementation` window made shorter): any administrator of the
  organization, or the platform operator.
- **Lower it**: the organization's sole administrator, counting everyone who has ever held the Administrator role
  (an administrator who was revoked, deactivated or taken off a team still counts), or the platform operator.
- Anyone else is refused, with "a lower approval posture needs the sole administrator, an operator, or a change
  approved under four eyes".

The platform operator is the person `mix ash_enterprise.platform.grant_operator --email <operator>` made (see the
[crypto-shredding runbook](crypto-shredding.md#operator-setup)). The platform, not the tenant, vouches for them, so
they can unblock a tenant whose only administrator cannot.

## Setting it

There is no settings page for it yet. From a shell, for a new tenant's first agent, as its administrator:

```bash
devenv shell -- mix ash_enterprise.assistant.enable --org <unique_name> --as <admin email> --posture small_team
```

As the platform operator, in IEx, for any organization:

```elixir
org = AshEnterprise.Accounts.Organization |> Ash.get!(org_id, authorize?: false)

org
|> Ash.Changeset.for_update(:set_approval_posture,
  %{approval_posture: :implementation, approval_posture_ends_at: DateTime.add(DateTime.utc_now(), 30, :day)},
  actor: operator_actor,
  tenant: org.id
)
|> Ash.update!()
```

Always pass the organization's own id as `tenant`: the posture rules read the administrators of that tenant.

## Verify

`approval_basis` on each approved invocation says what the approval rested on: `four_eyes`, `small_team` (the
requester approved their own request) or `implementation`. Every posture change is an audited update of the
organization.
