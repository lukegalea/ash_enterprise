# security_alerts

Opens a review, for an administrator other than the people involved, when a high-risk
security event is recorded: a privileged role reaching someone (assigned, brought back into
force after it ended, or reaching them through a team), a break-glass session
approved, an API key issued, a known person's sign-in refused a third time in a row, or an
inbound alert labelled `security`. `pack.json` lists the recipes; `review_security_alert.bpmn`
is the review. Installed as drafts: nothing runs until a person publishes the process and
the recipes (`AshEnterprise.Bpmn.Packs`).

## What makes a role privileged

What it grants, never its name. A role is privileged when it holds at least one privileged
privilege (`AshEnterprise.Security.Privilege.privileged?/3`), and a privilege is privileged
when:

- its resource is operator-only (`Privilege.operator_only_resources/0`), at any verb;
- its verb reaches an action the resource declares `changes_authority`
  (`AshEnterprise.Security.ActionReach`), mapped by `AccessRight.for_action_type/1`; or
- its verb writes (`create`, `write`, `delete`, `assign`, `share`) a resource of the
  Accounts or Security domain.

Read counts where a resource declares a generic action `changes_authority` (a release
manifest's promotion, an agent version's publication, a recipe's re-drive): a `:global` read
grant authorizes a generic action (`AshEnterprise.Security.Checks.RoleGrant`), so it reaches
them. A narrower read does not, and is still counted: the rule ignores depth. A secured
column's privilege (`"Resource#field"`) is privileged only when its resource is
operator-only. Reading who holds what is not privileged, nor is writing a resource that
administers nothing. So the tenant's Administrator and the Platform Operator are privileged,
the starter Data Steward, Judgment certifier and On-call roles are not, a custom role that
can assign roles is, a renamed one still is, and a role called "Administrator" that grants
nothing is not.

The rule is derived from the resources' declarations, so a new resource that declares
`changes_authority` is covered without editing this pack.

## Where the guards read it

A guard must not query, so the write that grants a role stamps the answer into its audit
metadata on its own write path (`StampRoleName`, `StampTeamGrant`, `StampPrivilegeGrant`,
through `AshEnterprise.Security.PrivilegedRoles`):

| Recipe | Event | Stamp |
|---|---|---|
| `privileged_role_assigned` | `UserRole` create | `privileged`, `role_name` |
| `privileged_role_assigned_to_team` | `TeamRole` create | `privileged`, `role_name` |
| `privileged_role_revived` | `UserRole.set_valid_until` | `revived`, `privileged`, and `role_name` when it revived |
| `privileged_team_role_revived` | `TeamRole.set_valid_until` | as for a person's grant |
| `privileged_team_joined` | `TeamMembership` create | `privileged`, `role_names`, `privileged_role_names` |
| `privileged_team_restored` | `Team.restore` | as for joining |
| `held_role_made_privileged` | `RolePrivilege` create | `privileged`, and `role_name` when it is |

The guards read `metadata.privileged`. An event stamped before version 3 carries only the
role's name, so the role guards fall back to the name for an event with no `privileged` key
(`if metadata.privileged = null then <the name> else metadata.privileged = true`); a stamped
event never does. The guard is an `if` rather than an `or` because this FEEL engine answers
null, not true, for `true or null`.

A grant whose `valid_until` has passed grants nothing, and its row stays. Clearing that end,
or moving it past now, gives the role back without a create, so the revival recipes match
`set_valid_until` and read what `StampGrantRevival` stamped: `privileged` is true only when
the grant was not in force before the write, is after it, and the role is privileged.
Moving the end of a grant still in force hands nobody anything new and opens nothing here
(the `soc2_cc6_3` pack reviews a person's extended grant). The team revival's review is
offered to none of the team's members (`team_grantees`), the person's to none of them
(`subject.user_id`).

`held_role_made_privileged` fires when a role someone holds now, directly or through a team,
is granted its first privileged privilege. A role that already was privileged (the
Administrator gaining a new resource's privileges at deploy, a repeated grant) adds nothing,
and a role nobody holds raises the alarm when it is assigned or a person joins a team that
holds it. Its review is offered to none of the role's holders (`role_holders`).

## What it does not do

It does not alarm on revoking a role, narrowing a grant or changing an approval posture:
those are audited and only logged. The review records that someone answered, not that the
answer was right. Its candidates are still found by name: the holders of a role named
"Administrator" (the tenant's keeps its name, `AdministratorKeepsItsName`). A second role of
that name, in another business unit, makes its holders candidates too.
