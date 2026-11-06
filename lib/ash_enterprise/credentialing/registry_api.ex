defmodule AshEnterprise.Credentialing.RegistryApi do
  @moduledoc """
  The credential registry's declared operations (`AshOperations`, ADR 0063): one generic
  action and one code interface per operation, a vendored spec pinned by sha-256, and
  `AshEnterprise.Credentialing.RegistryApi.Transport` as the registry's only HTTP client.

  Tier 3 and confined (ADR 0011): delete `credentialing/registry_api*` and the registry's
  `Registry.FakeProvider`, restore the `Registry` calls in `Changes.ActivateInRegistry`
  and `Actions.LookupActivation`, and the template is back to the ETS stub.

  | Operation | Effect | What it is |
  |---|---|---|
  | `activate` | write, not idempotent | Activates a credential. A lost answer is `:ambiguous`, reconciled through `list_activations`, never re-sent. Sends the licence number, so it discloses |
  | `list_activations` | read | The registry's activations for a credential reference: what `activate` is reconciled through |
  | `get_activation` | read | One activation by the id the registry gave it |

  ## Who may call: the governed act, and nothing else

  No tenant role reaches this resource: it is operator-only
  (`AshEnterprise.Security.Privilege.operator_only?/1`), so the Administrator auto-grant skips
  it. A grant here would let any holder call `activate` directly and skip the four-eyes approval
  on `Credential.activate_credential`. Its one additive grant is
  `AshEnterprise.Security.Checks.GovernedCall`, which admits a call that carries the invocation
  that is governing it (the executor's and the reconciler's calls do). The system actors keep
  their own bypass, which is how the webhook follow-up reads `get_activation`.

  ## The credential reference

  `reference` (the wire's `subjectReference`; the package refuses a name that says "credential") is minted by the host as `"<organization_id>:<credential_id>"`
  (`AshEnterprise.Credentialing.RegistryApi.reference/2`): opaque to the registry and not
  personal data. The only consumer that turns one back into a tenant is the webhook
  follow-up, and it reads the reference from an authenticated `get_activation`, never from a
  webhook payload.

  ## Disclosure

  `activate` sends the licence number, which is personal data leaving the zone (ADR 0042).
  `AshEnterprise.Credentialing.RegistryDisclosureGate` decides before anything is sent;
  `disclosure_ref` is the credential's id.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Credentialing,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    extra_grants: [AshEnterprise.Security.Checks.GovernedCall],
    extensions: [AshOperations]

  # Generic actions only and no rows, but the platform's system attributes are still
  # fields, which trips Ash's primary-key check for stored resources.
  resource do
    require_primary_key? false
  end

  operations do
    provider :credential_registry
    transport AshEnterprise.Credentialing.RegistryApi.Transport
    spec "priv/vendor/credential_registry/openapi.json"
    spec_sha256 "a813b92aa275244bac9752ddf52622fe96006beff316d23698c184f61ff02e28"
    disclosure_gate AshEnterprise.Credentialing.RegistryDisclosureGate

    operation :activate, :post, "/v1/activations" do
      description "Activate a credential. Not idempotent: reconcile through list_activations."
      reconcile_with :list_activations
      discloses? true

      param :reference, :string,
        in: :body,
        as: "subjectReference",
        allow_nil?: false

      param :licence_number, :string,
        in: :body,
        as: "licenceNumber",
        sensitive?: true
    end

    operation :list_activations, :get, "/v1/activations" do
      description "The registry's activations for a credential reference."
      param :reference, :string, as: "subjectReference"
      param :page_size, :integer, as: "pageSize", constraints: [min: 1, max: 100]
    end

    operation :get_activation, :get, "/v1/activations/{activation_id}" do
      description "One activation, by the id the registry gave it."
      param :activation_id, :string, in: :path
    end
  end

  @doc """
  The options a call to this resource takes when it is made for a governed invocation: the
  caller's actor and tenant, and the invocation's own context (`context.ash_agent`), which is
  what `AshEnterprise.Security.Checks.GovernedCall` admits.
  """
  @spec governed_opts(map(), map() | nil) :: keyword()
  def governed_opts(context, ash_agent) do
    context
    |> Ash.Context.to_opts()
    |> Keyword.put(:context, if(ash_agent, do: %{ash_agent: ash_agent}, else: %{}))
  end

  @doc """
  The reference the registry is given for a credential: `"<organization_id>:<credential_id>"`.
  """
  @spec reference(Ash.UUID.t(), Ash.UUID.t()) :: String.t()
  def reference(organization_id, credential_id), do: "#{organization_id}:#{credential_id}"

  @doc """
  Split a reference back into `{organization_id, credential_id}`, or `:error` when it is not
  two UUIDs.
  """
  @spec parse_reference(term()) :: {:ok, {Ash.UUID.t(), Ash.UUID.t()}} | :error
  def parse_reference(reference) when is_binary(reference) do
    with [organization_id, credential_id] <- String.split(reference, ":"),
         {:ok, organization_id} <- Ecto.UUID.cast(organization_id),
         {:ok, credential_id} <- Ecto.UUID.cast(credential_id) do
      {:ok, {organization_id, credential_id}}
    else
      _ -> :error
    end
  end

  def parse_reference(_reference), do: :error
end
