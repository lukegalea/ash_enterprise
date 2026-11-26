defmodule AshEnterprise.Provenance.DispatchOrderTest do
  @moduledoc """
  The dispatch order (ADR 0078, section 4), pinned for `Canonical.Person.email`:
  no package or derived explainer claims the sealed address, the audit explainer
  answers at `:record` granularity, and after the person's scope is shredded the
  answer is `:erased` — with the receipt named only to a reader who may read one.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 1, member!: 3, person!: 3]

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.PersonErasure
  alias AshEnterprise.Provenance

  @email_domain "dispatch-order.synthetic.test"

  setup do
    %{
      operator: tenant!(operator?: true),
      email: "sealed-#{System.unique_integer([:positive])}@#{@email_domain}"
    }
  end

  # The reader owns the person (a `:basic` read reaches what one owns), so the
  # same person is created under their name and erased by the operator.
  defp owned_reader(operator, extra_grants, email) do
    reader =
      member!(
        operator,
        "Order reader #{System.unique_integer([:positive])}",
        [
          {Person, :read, :basic}
        ] ++ extra_grants
      )

    %{
      reader: reader,
      person: person!(reader, email, "Sealed #{System.unique_integer([:positive])}")
    }
  end

  defp erase!(operator, email) do
    assert {:ok, _receipt} =
             Erasure.erase_person(email, email, "dispatch order test",
               actor: operator.actor,
               tenant: operator.tenant
             )
  end

  describe "the order" do
    test "the derived explainer is asked first and passes the sealed address", %{
      operator: operator
    } do
      assert Provenance.Registry.explainers_for(Person, :email) == [
               AshEnterprise.Provenance.Explainers.Derived,
               AshEnterprise.Provenance.Explainers.Audit,
               AshEnterprise.Provenance.Explainers.RecordColumns
             ]

      # `email` is an `Unseal` calculation: not a derivation, so the derived
      # explainer passes and the audit explainer answers.
      {:ok, address} =
        AshProvenance.Address.new(
          base: Provenance.base(),
          type: "person",
          id: Ash.UUID.generate(),
          attribute: "email"
        )

      subject = %{
        address: address,
        resource: Person,
        record: nil,
        field: :email,
        value: nil
      }

      ctx = %{
        actor: operator.actor,
        tenant: operator.tenant,
        base: Provenance.base(),
        registry: Provenance.Registry,
        cache: %{}
      }

      assert :pass = AshEnterprise.Provenance.Explainers.Derived.explain(subject, ctx)
    end
  end

  describe "the audit answer" do
    test "is record granularity for the sealed address, with no value anywhere", %{
      operator: operator,
      email: email
    } do
      %{reader: reader, person: person} =
        owned_reader(operator, [{EventLog, :read, :global}], email)

      result = explain(reader, "person", person.id, "email")
      assert {:ok, %{explanation: explanation}} = result

      generated = step(explanation, :was_generated_by)
      assert generated.granularity == :record
      assert is_nil(generated.value)

      refute Enum.any?(explanation.steps, &(&1.relation == :was_derived_from))

      # The address string appears nowhere: the log holds the ciphertext of
      # `encrypted_email`, and the calculation that reads it is `sensitive?`.
      refute inspect(result) =~ email
    end
  end

  describe "after the person is erased" do
    test "the answer is an erased gap, with the receipt for a reader who may read one", %{
      operator: operator,
      email: email
    } do
      %{reader: reader, person: person} =
        owned_reader(
          operator,
          [
            {EventLog, :read, :global},
            {PersonErasure, :read, :global}
          ],
          email
        )

      erase!(operator, email)

      {:ok, %{explanation: explanation}} = explain(reader, "person", person.id, "email")

      assert [%{kind: :erased} = gap] = Enum.filter(explanation.gaps, &(&1.kind == :erased))
      assert gap.of.attribute == "email"

      assert %{id: receipt_id} =
               PersonErasure |> Ash.read_one!(tenant: operator.tenant, authorize?: false)

      assert gap.receipt == "person_erasure:" <> to_string(receipt_id)

      # The write history is not erased: the audit explainer still answers.
      assert step(explanation, :was_generated_by).granularity == :record
      refute inspect(explanation) =~ email
    end

    test "without receipt access, erased and nothing more", %{
      operator: operator,
      email: email
    } do
      %{reader: reader, person: person} =
        owned_reader(operator, [{EventLog, :read, :global}], email)

      erase!(operator, email)

      {:ok, %{explanation: explanation}} = explain(reader, "person", person.id, "email")

      assert [%{kind: :erased} = gap] = Enum.filter(explanation.gaps, &(&1.kind == :erased))
      assert is_nil(gap.receipt)

      # Nothing else says a receipt exists.
      refute inspect(explanation) =~ "person_erasure:"
      refute inspect(explanation) =~ email
    end
  end

  defp explain(ctx, type, id, attribute) do
    Provenance.explain("#{Provenance.base()}/#{type}/#{id}##{attribute}",
      actor: ctx.actor,
      tenant: ctx.tenant
    )
  end

  defp step(explanation, relation), do: Enum.find(explanation.steps, &(&1.relation == relation))
end
