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
  - **Under the flow guard, a sub-processor is refused for everyone.** With
    `REQUIRE_IN_ZONE_MODELS` set (`AshEnterprise.AI.Models.require_in_zone?/0`)
    a recorded opt-in no longer suffices: the deployment has said nothing
    leaves the zone for inference.
  - **A tenant-designated destination is allowed for that tenant.** An
    outbound webhook endpoint (`AshEnterprise.Integration.Outbound.Endpoint`)
    is a URL the tenant registered itself, so the registration is the
    recorded authorization, audited like any other write. The class is
    `:tenant_designated`; it is allowed for a tenant that resolves to an
    organization, and only for that tenant's own endpoints (the outbound
    disclosure gate checks the endpoint is the tenant's). The flow guard does
    not apply: it is about inference, and the tenant chose this destination.
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

  The host's own model-call guard (`AshEnterprise.AI.Models.check/3`) calls
  it too, as `allow?(tenant, :sub_processor, :generative)`, for every call to
  a model outside the zone: one rule for the judgment path and every other AI
  path (ADR 0026 as amended).
  """

  @behaviour AshJudgments.ResidencyPolicy

  alias AshEnterprise.Accounts.Organization

  @impl AshJudgments.ResidencyPolicy
  def allow?(_tenant, :in_cluster, _family), do: true

  # Under the flow guard (REQUIRE_IN_ZONE_MODELS, `AshEnterprise.AI.Models`)
  # nothing outside the zone is an instrument, whatever a tenant recorded.
  def allow?(tenant, :sub_processor, _family),
    do: not AshEnterprise.AI.Models.require_in_zone?() and opted_in?(tenant)

  # A destination the tenant registered itself: allowed for a tenant that exists.
  def allow?(tenant, :tenant_designated, _family), do: organization?(tenant)

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

  defp organization?(%Organization{}), do: true

  defp organization?(id) when is_binary(id) do
    match?({:ok, %Organization{}}, Ash.get(Organization, id, authorize?: false))
  end

  defp organization?(_), do: false

  defp fetch_opt_in(id) do
    case Ash.get(Organization, id, authorize?: false) do
      {:ok, %Organization{} = organization} -> organization.sub_processor_opt_in
      {:error, _} -> false
    end
  end
end
