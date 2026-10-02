defmodule AshEnterprise.Zones.ResidencyPolicy do
  @moduledoc """
  This host's answer to `AshJudgments.ResidencyPolicy`: may this tenant's
  data be answered by an instrument of this residency class?

  The zone reality of this deployment ([ADR 0042](../../../docs/adr/0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md),
  [ADR 0048](../../../docs/adr/0048-a-judgment-is-a-predicate-over-any-set.md)):

  - **In-cluster is allowed, for everyone.** An in-cluster instrument runs
    inside the data's own declared zone (the Ontario zone,
    `priv/zones/examples/ontario.json` is its declaration shape). ADR 0042:
    a call to an instrument in the data's own zone is not an outbound
    disclosure — it is recorded in the judgment ledger. There is nothing for
    a tenant to opt into.
  - **A sub-processor is refused unless the tenant has recorded an opt-in.**
    ADR 0042 narrowed ADR 0026: for customer-confidential data the control
    is an **opt-in**, not an opt-out, and it is *recorded* — so it is data on
    the tenant (`Organization.sub_processor_opt_in`), policed like any other
    attribute and written to the audit event log like any other update.
    Deliberately **not** config: a flag in a config file is nobody's
    recorded authorization.
  - **Everything unknown is refused.** No tenant, an unresolvable tenant id,
    or a failed read is a refusal — a tenant never opts in by silence. A
    residency class this policy does not know is a refusal too, so a future
    class in the package cannot start leaking by default.

  Registered with the package in `config/runtime.exs`:

      config :ash_judgments, :residency_policy, AshEnterprise.Zones.ResidencyPolicy

  The package calls `allow?/3` from `AshJudgments.Profile.model_spec/3` —
  in the action path, next to the client, never inside an Ash policy check
  (law 3) — and turns a `false` into a structured `ResidencyDenied` with no
  call made.
  """

  @behaviour AshJudgments.ResidencyPolicy

  alias AshEnterprise.Accounts.Organization

  @impl AshJudgments.ResidencyPolicy
  def allow?(_tenant, :in_cluster, _family), do: true

  def allow?(tenant, :sub_processor, _family), do: opted_in?(tenant)

  # Fail closed: a residency class this host has not ruled on is refused,
  # whatever the tenant has recorded.
  def allow?(_tenant, _residency, _family), do: false

  # The recorded opt-in, read per call next to the client. The package
  # deliberately routes this through the host rather than through a policy
  # check, so the read is expected here; a tenant value is the action's own
  # tenant context, not request input to be authorized against.
  defp opted_in?(%Organization{} = organization), do: organization.sub_processor_opt_in
  defp opted_in?(id) when is_binary(id), do: fetch_opt_in(id)

  # nil (no tenant on the action), an integer, or anything else: nothing
  # recorded, nothing allowed.
  defp opted_in?(_), do: false

  defp fetch_opt_in(id) do
    case Ash.get(Organization, id, authorize?: false) do
      {:ok, %Organization{} = organization} -> organization.sub_processor_opt_in
      {:error, _} -> false
    end
  end
end
