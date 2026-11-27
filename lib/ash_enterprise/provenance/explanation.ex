defmodule AshEnterprise.Provenance.Explanation do
  @moduledoc """
  The answer to "where did this value come from" (ADR 0078): computed, never
  stored. `explain` takes one address (`<base>/<type>/<id>#<attribute>`) and
  answers an `AshProvenance.Explanation` — steps and typed gaps — beside a map
  from each audit step's activity reference to the correlation id of the write
  it recorded, so a surface can link to `AshEnterprise.Execution`'s `trace`
  (which takes a correlation id).

  It is read in one tenant and refused without one, exactly as
  `AshEnterprise.Execution.Entry.trace` is: every read the walk makes is
  organization-scoped, and a read with no tenant applies no organization
  filter, so a grant that reaches everything in a tenant would otherwise reach
  every tenant's rows under the address given.

  Everything the answer holds came out of reads made as the caller, through
  each record's own read action; that is why the action is self-service
  (ADR 0052). The dispatch order and the bounds of the walk are
  `AshEnterprise.Provenance.Registry`'s and `AshEnterprise.Provenance.Walk`'s.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Provenance,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:explain, :why]

  resource do
    require_primary_key? false
  end

  actions do
    action :explain, :map do
      description "Where one readable value came from, as the reader may see it."

      constraints fields: [
                    explanation: [
                      type: :struct,
                      constraints: [instance_of: AshProvenance.Explanation],
                      allow_nil?: false
                    ],
                    correlation_ids: [type: :map, allow_nil?: false]
                  ]

      argument :address, :string do
        allow_nil? false

        description "<base>/<type>/<id>[?as_of=<instant>]#<attribute> (ADR 0078, section 1)."
      end

      run AshEnterprise.Provenance.Explanation.Explain
    end

    action :why, {:array, :map} do
      description """
      The same answer as `explain`, as the rows a person reads
      (`AshEnterprise.Provenance.Why`): the Why page runs this.
      """

      argument :address, :string do
        allow_nil? false

        description "<base>/<type>/<id>[?as_of=<instant>]#<attribute> (ADR 0078, section 1)."
      end

      run AshEnterprise.Provenance.Explanation.Why
    end
  end
end
