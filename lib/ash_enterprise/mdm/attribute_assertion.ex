defmodule AshEnterprise.Mdm.AttributeAssertion do
  @moduledoc """
  One statement that a field of a person has a value, and where that came
  from (`AshMdm.Resources`, `:attribute_assertion`). A person's `name` and
  `email` are the fold of these (`AshEnterprise.Mdm.Refold`).

  Append-only. A merge moves no rows: an absorbed person's statements stay
  where they are and the survivor folds through `master_id`, which is what
  makes an unmerge correct.

  ## Who can read one

  Whoever can read the person it is about. Every read carries an unrelated
  `exists` over Person, which Ash authorizes with Person's own read policy, as
  `AshEnterprise.Mdm.MatchCandidate`'s review queue does: a session that cannot
  see a person learns nothing from here. It is a preparation and not a policy
  expression because Ash does not authorize an `exists` inside a policy, so
  the same filter there would let every colleague read every person's
  statements. There is no role grant to hold on this resource. Writes are the
  machinery's.

  ## Personal data (ADR 0024, ADR 0042)

  A value is a name or an address, in plaintext, like the Person row it feeds,
  and outside any erasure scope. `sensitive_value?` keeps it out of logs and
  inspection. Deleting a Person row does not remove these (there is no foreign
  key); `docs/runbooks/crypto-shredding.md` lists them with the person's other
  rows.

  `audit?: false`, as `SourceRecord` and `SourceIdentity`: the row is itself the
  record, and auditing each would take the tenant's event-log lock once per
  field per import.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :organization_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    policies?: false

  use AshMdm.Resources,
      {:attribute_assertion,
       repo: AshEnterprise.Repo,
       table: "mdm_attribute_assertions",
       tenant?: true,
       sensitive_value?: true,
       digest_secret: {AshEnterprise.Mdm.AssertionDigestKey, :key, []}}

  import Ash.Expr, only: [expr: 1]

  preparations do
    prepare build(filter: expr(exists(AshEnterprise.Canonical.Person, id == parent(golden_id))))
  end

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    # Row access is the preparation above; see the moduledoc.
    policy action_type(:read) do
      authorize_if always()
    end
  end
end
