/**
 * The leverage specimen, as data.
 *
 * The "What a declaration carries" section renders every box, chip and outcome
 * list from this one map, so the fragment → extension → derived-outcomes
 * relationship cannot silently drift apart between the plate and the legend.
 * The `code` fields are quoted from the repository; trim marks are comments,
 * never elisions that change meaning.
 */

/** The Atelier hue a box is keyed to — one of the accent tokens. */
export type SpecimenKey = 'workshop' | 'blueprint' | 'copper';

export interface SpecimenFragment {
  /** Grouping id for the hover/focus sync between box, chip and outcome. */
  id: string;
  /** Small mono label printed on the box, e.g. `→ ash_strangler`. */
  label: string;
  /** Chip and outcome-entry name. */
  extension: string;
  href: string;
  external: boolean;
  key: SpecimenKey;
  code: string;
  /** Where the fragment lives in the repository. */
  sourcePath: string;
  annotation: string;
  /** The "what each box gives you" rows. */
  gives: string[];
}

export const specimenFragments: SpecimenFragment[] = [
  {
    id: 'platform',
    label: '→ platform.resource',
    extension: 'AshEnterprise.Platform.Resource',
    href: 'https://github.com/lukegalea/ash_enterprise/blob/main/lib/ash_enterprise/platform/resource.ex',
    external: true,
    key: 'workshop',
    code: `use AshEnterprise.Platform.Resource,
  domain: AshEnterprise.Accounts,
  api_type: :team,
  ownership: :business_owned,
  cdm_entity: "Team"

# only what is specific to Team.
attributes do
  attribute :name, :string,
    allow_nil?: false, public?: true
end`,
    sourcePath: 'lib/ash_enterprise/accounts/team.ex',
    annotation:
      'This line injects Ash.Policy.Authorizer, AshEvents audit, AshArchival, AshStateMachine, tenant scope, and A2UI metadata.',
    gives: [
      'Ash.Policy.Authorizer — the grant union below',
      'AshEvents — every action in the hash-chained log',
      'AshArchival — soft deletion, cascading',
      'AshStateMachine — the lifecycle states',
      'Multitenancy — the organization scope',
      'A2UI metadata — agent-visible actions',
    ],
  },
  {
    id: 'policy',
    label: '→ Ash.Policy.Authorizer',
    extension: 'Ash.Policy.Authorizer',
    href: 'https://hexdocs.pm/ash/Ash.Policy.Authorizer.html',
    external: true,
    key: 'blueprint',
    code: `policies do
  # Non-human actors bypass the role model
  # entirely -- named, narrow, still attributed.
  bypass AshEnterprise.Security.Checks.SystemActor do
    authorize_if always()
  end

  # The union. Each clause is one grant path; any
  # one succeeding is sufficient; none subtracts.
  policy always() do
    authorize_if AshEnterprise.Security.Checks.RoleGrant
    authorize_if AshEnterprise.Security.Checks.SharedWithActor
    authorize_if AshEnterprise.Security.Checks.HierarchyGrant
  end
end`,
    sourcePath: 'lib/ash_enterprise/security/policies.ex',
    annotation: 'Not written on this resource — injected by the use line.',
    gives: [
      'Role grants, resolved per action',
      'Per-record shares, as rows',
      'The manager and position hierarchy',
      'Fail closed when no path authorizes',
    ],
  },
  {
    id: 'strangler',
    label: '→ ash_strangler',
    extension: 'ash_strangler',
    href: 'https://hexdocs.pm/ash_strangler/',
    external: true,
    key: 'copper',
    code: `strangler do
  phase(:read_from_legacy)

  source AshEnterprise.Legacy.Twins.ClmContracts do
    # ... eleven map/2 column mappings ...

    collapse :lifecycle_status do
      hit_policy(:first)

      state(:archived,
        when: expr(not is_nil(archived)),
        set: [processed: false, verified: false, archived: touch()])

      state(:unverified,
        when: expr(processed and not verified),
        set: [processed: true, verified: false, archived: nil])

      state(:active,
        when: expr(processed and verified),
        set: [processed: true, verified: true, archived: nil])

      state(:processing,
        when: :otherwise,
        set: [processed: false, verified: false, archived: nil])
    end
  end
end`,
    sourcePath: 'lib/ash_enterprise/contracts/resources.ex',
    annotation: 'Legacy boolean columns become a legal state machine.',
    gives: [
      'A compatibility view over the legacy table',
      'INSTEAD OF triggers for the dual-write phase',
      'A resumable, reversible backfill',
      'A drift reconciler and a lineage graph',
    ],
  },
];

/** Resolves a key name to its CSS colour variable. */
export const keyVar: Record<SpecimenKey, string> = {
  workshop: 'var(--ae-workshop)',
  blueprint: 'var(--ae-blueprint)',
  copper: 'var(--ae-copper)',
};
