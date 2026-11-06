defmodule AshEnterprise.Planning.ModelVersion do
  @moduledoc """
  One immutable planning model version (ADR 0062): `AshPlanning.Fragment.ModelVersion`
  on the platform base, in table `planning_model_versions`.

  The fragment supplies the contract: `(key, version)` identity, the model, checker and
  validator hashes, the backend profile, the capability set, and the `draft → published →
  retired` lifecycle with its immutability after publish. This resource supplies what the
  fragment deliberately leaves out: tenancy, audit, the Postgres table and the policies.

  ## Posture

    * **Organization-owned configuration.** A model version is reviewed artifact metadata,
      not anyone's task: it carries no owner, and reading or writing it takes a role grant.
      Publishing is an ordinary audited update, so "who published which hash, when" is an
      event in the audit log.
    * **Never removed.** A run pins a version by id (`restrict` on delete), so a version is
      retired, not destroyed; there is no destroy action and no soft delete.
    * **Not a lifecycle resource.** `status` is the fragment's own axis, so the platform's
      `state_code`/`status_code` lifecycle is off.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Planning,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    fragments: [AshPlanning.Fragment.ModelVersion]

  postgres do
    table "planning_model_versions"
    repo AshEnterprise.Repo
  end
end
