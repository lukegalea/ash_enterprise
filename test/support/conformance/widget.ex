defmodule AshEnterprise.Conformance.Widget do
  @moduledoc """
  A deliberately meaningless `:user_owned` resource, used only by the
  authorization conformance suite.

  ## Why a fake resource

  The conformance suite tests the *engine*, and the engine's behaviour depends on
  the ownership model and nothing else. Testing it against a real business entity
  would entangle the truth table with that entity's own validations, required
  fields and lifecycle — and every future change to that entity would perturb
  security tests for no reason.

  It also fills a genuine gap: none of the platform's own resources are
  `:user_owned`. Organization is organization-owned; BusinessUnit, Team and Role
  are business-owned; the join tables are unowned. So without this there is no way
  to exercise the `:basic` depth at all, which is the depth most likely to be
  wrong.

  ## Why the ETS data layer

  Ash policy checks produce data-layer-agnostic filter expressions, so the
  authorization *decisions* are identical on ETS and Postgres. Using ETS keeps
  this resource out of the production migration set entirely — a test-only table
  in `priv/repo/migrations` would ship to every deployment of this template.

  The Postgres path is not left untested: `business_unit_test.exs` exercises the
  materialized-path SQL, and the policy tests against real resources run through
  AshPostgres.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Conformance,
    ownership: :user_owned,
    data_layer: Ash.DataLayer.Ets,
    audit?: false,
    archival?: false,
    # Two self-service actions (ADR 0052), so the conformance suite can pin
    # the fourth grant path: `:mine` reaches only the actor's own widgets,
    # `:whoami` is a generic action scoped to the actor by construction.
    self_service: [:mine, :whoami],
    # ADR 0059: an update and a generic action of each narrowed kind, so the
    # conformance suite can pin which bypasses reach them.
    human_only: [:approve, :sign_off],
    machinery_only: [:claim, :sweep]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:name, :owner_id, :owner_type, :owning_business_unit_id, :owning_user_id]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end

    read :mine do
      description "Self-service: the actor's own widgets, with no role grant."
    end

    update :approve do
      description "Human-only: a person's own decision; no bypass reaches it."
      accept []
    end

    action :sign_off, :boolean do
      description "Human-only generic action."
      run fn _input, _context -> {:ok, true} end
    end

    update :claim do
      description "Machinery-only: the job runner's alone; no grant reaches it."
      accept []
    end

    action :sweep, :boolean do
      description "Machinery-only generic action."
      run fn _input, _context -> {:ok, true} end
    end

    action :whoami, :string do
      description "Self-service: answers with the actor's own id and nothing else."
      run fn _input, context -> {:ok, to_string(context.actor.id)} end
    end
  end

  code_interface do
    define :create
    define :read
  end
end
