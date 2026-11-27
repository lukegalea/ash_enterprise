defmodule AshEnterprise.Provenance.DerivedGapsTest.Domain do
  @moduledoc """
  The test domain for `AshEnterprise.Provenance.DerivedGapsTest`: a thing and
  the parts a relationship of its names.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEnterprise.Provenance.DerivedGapsTest.Thing
    resource AshEnterprise.Provenance.DerivedGapsTest.Part
  end
end

defmodule AshEnterprise.Provenance.DerivedGapsTest.Part do
  @moduledoc """
  A part of a thing: the destination the thing's `has_many :things` names.
  """

  use Ash.Resource,
    domain: AshEnterprise.Provenance.DerivedGapsTest.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  actions do
    defaults [:read, :create]
    default_accept [:thing_id, :a]
  end

  attributes do
    uuid_primary_key :id
    attribute :thing_id, :uuid, public?: true
    attribute :a, :string, public?: true
  end
end

defmodule AshEnterprise.Provenance.DerivedGapsTest.EmptyLoad do
  @moduledoc """
  A module calculation that names no input: its `load/3` returns `[]`.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: []

  @impl true
  def calculate(records, _opts, _context), do: Enum.map(records, fn _record -> "nothing" end)
end

defmodule AshEnterprise.Provenance.DerivedGapsTest.OverThings do
  @moduledoc """
  A module calculation that reads a relationship: its `load/3` names `things`.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [things: [:a]]

  @impl true
  def calculate(records, _opts, _context), do: Enum.map(records, fn _record -> "parts" end)
end

defmodule AshEnterprise.Provenance.DerivedGapsTest.Thing do
  @moduledoc """
  An ETS thing whose calculations give the derived explainer nothing to name:
  an expression over no field, a module calculation loading nothing, and a
  function calculation. One more loads through a relationship.
  """

  use Ash.Resource,
    domain: AshEnterprise.Provenance.DerivedGapsTest.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  actions do
    defaults [:read, :create]
    default_accept [:a]
  end

  attributes do
    uuid_primary_key :id
    attribute :a, :string, public?: true
  end

  relationships do
    has_many :things, AshEnterprise.Provenance.DerivedGapsTest.Part do
      destination_attribute :thing_id
      public? true
    end
  end

  calculations do
    calculate :nowish, :string, expr(now()) do
      public? true
    end

    calculate :nothing_loaded, :string, AshEnterprise.Provenance.DerivedGapsTest.EmptyLoad do
      public? true
    end

    calculate :counted, :string, fn records, _context ->
      Enum.map(records, fn _record -> "counted" end)
    end do
      public? true
    end

    calculate :over_things, :string, AshEnterprise.Provenance.DerivedGapsTest.OverThings do
      public? true
    end
  end
end

defmodule AshEnterprise.Provenance.DerivedGapsTest.Registry do
  @moduledoc """
  The walk's registry for the test thing, with the host's dispatch order: the
  thing is not in the host registry, because a test-only resource must not
  answer production addresses.
  """

  @thing AshEnterprise.Provenance.DerivedGapsTest.Thing

  def resource("derived_gap_thing"), do: {:ok, @thing}
  def resource(_token), do: :error

  def token(@thing), do: {:ok, "derived_gap_thing"}
  def token(_resource), do: :error

  def explainers_for(_resource, _field) do
    [
      AshEnterprise.Provenance.Explainers.Derived,
      AshEnterprise.Provenance.Explainers.Audit,
      AshEnterprise.Provenance.Explainers.RecordColumns
    ]
  end
end

defmodule AshEnterprise.Provenance.DerivedGapsTest do
  @moduledoc """
  The rule an explanation never breaks (ADR 0078): an answer never reads as
  explained when the evidence does not support it. A calculation the derived
  explainer can name nothing for — an expression over no field, a module
  calculation whose `load/3` names nothing, a function calculation — is a pass,
  so the walk says `:not_recorded` instead of an empty answer. A `load/3` that
  names a relationship is one record-granularity step over it, never dispatched
  again.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{Credential, LicenceDocument}
  alias AshEnterprise.Provenance
  alias AshEnterprise.Provenance.Walk
  alias AshEnterprise.Provenance.Why
  alias AshProvenance.Address
  alias AshProvenance.Gap

  setup do
    %{admin: tenant!()}
  end

  describe "a calculation nothing names" do
    test "an expression over no field answers as not recorded", %{admin: _admin} do
      assert_not_recorded("nowish")
    end

    test "a module calculation whose load names nothing answers as not recorded", %{
      admin: _admin
    } do
      assert_not_recorded("nothing_loaded")
    end

    test "a function calculation answers as not recorded", %{admin: _admin} do
      assert_not_recorded("counted")
    end
  end

  test "a module calculation loading through a relationship explains over it", %{admin: _admin} do
    thing = create_thing!()

    assert {:ok, %{explanation: explanation}} = explain(thing, "over_things")

    assert [step] = explanation.steps
    assert step.relation == :was_derived_from
    assert step.granularity == :record
    assert step.summary == "calculation over things"
    assert step.antecedent.attribute == "things"
    # The relationship step is not dispatch material: nothing follows it.
    assert explanation.gaps == []
  end

  test "a real calculation over a relationship names the relationship", %{admin: admin} do
    unique = System.unique_integer([:positive])

    clinic = Credentialing.register_clinic!("Clinic #{unique}", as(admin))

    clinician =
      Credentialing.register_clinician!(
        %{
          first_name: "Synthetic",
          last_name: "Person",
          job_title: "Nurse",
          clinic_id: clinic.id
        },
        as(admin)
      )

    credential =
      Credentialing.record_credential!(
        %{
          kind: :licence,
          number: "LIC-#{unique}",
          expires_on: ~D[2030-01-31],
          clinician_id: clinician.id
        },
        as(admin)
      )

    reader =
      member!(admin, "Derived reader #{unique}", [
        {Credential, :read, :global},
        {LicenceDocument, :read, :global},
        {EventLog, :read, :global},
        {User, :read, :global}
      ])

    assert {:ok, %{explanation: explanation}} =
             Provenance.explain(
               "#{Provenance.base()}/credential/#{credential.id}#document_findings",
               as(reader)
             )

    assert [step] = explanation.steps
    assert step.relation == :was_derived_from
    assert step.granularity == :record
    assert step.summary == "calculation over licence_documents"
    assert step.antecedent.attribute == "licence_documents"
  end

  # -- Helpers -------------------------------------------------------------

  defp assert_not_recorded(field) do
    thing = create_thing!()

    assert {:ok, %{explanation: explanation}} = explain(thing, field)

    assert explanation.steps == []
    assert [%Gap{kind: :not_recorded} = gap] = explanation.gaps
    assert Address.to_iri(gap.of) == asked_iri(thing, field)

    assert [%{kind: :gap, relation: :not_recorded}] = Why.rows(explanation, %{})
  end

  defp create_thing! do
    AshEnterprise.Provenance.DerivedGapsTest.Thing
    |> Ash.Changeset.for_create(:create, %{a: "a"})
    |> Ash.create!()
  end

  defp explain(thing, field) do
    Walk.explain(asked_iri(thing, field),
      registry: AshEnterprise.Provenance.DerivedGapsTest.Registry
    )
  end

  defp asked_iri(thing, field) do
    "#{AshEnterprise.Provenance.base()}/derived_gap_thing/#{thing.id}##{field}"
  end

  defp as(ctx), do: [actor: ctx.actor, tenant: ctx.tenant]
end
