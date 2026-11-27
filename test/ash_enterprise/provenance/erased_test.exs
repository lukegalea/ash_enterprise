defmodule AshEnterprise.Provenance.ErasedTest do
  @moduledoc """
  Erased values in an explanation (ADR 0078, section 3): a value whose erasure
  scope was shredded reads as `AshEnterprise.Erasure.Shredded`, and the answer
  says so with a `:erased` gap — the write history is not erased, so the audit
  explainer still answers, at `:record` granularity, with no value. Through a
  derivation (`Canonical.Task.label` over the sealed `commitment`), the gap
  names the antecedent. The receipt is named only to a reader who may read one.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 1, member!: 3, scope!: 1, person!: 3]

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.PersonErasure
  alias AshEnterprise.Provenance

  setup do
    operator = tenant!(operator?: true)
    unique = System.unique_integer([:positive])
    ref = "test:erased-#{unique}"

    scope = scope!(ref)

    commitment = "Send the signed offer to Dana #{unique}"

    task =
      Task
      |> Ash.Changeset.for_create(
        :propose,
        %{
          commitment: commitment,
          evidence: commitment,
          source: "calendar",
          origin_type: "Elixir.AshEnterprise.Canonical.CalendarEvent",
          origin_id: Ash.UUID.generate(),
          erasure_scope_id: scope.id,
          proposer: "test",
          instrument: "deterministic",
          owner_id: operator.user.id,
          owning_user_id: operator.user.id,
          owning_business_unit_id: operator.user.owning_business_unit_id
        },
        tenant: operator.tenant,
        authorize?: false
      )
      |> Ash.create!()

    assert {:ok, _} =
             Erasure.shred_scope(scope, ref, "provenance erased test",
               actor: operator.actor,
               tenant: operator.tenant
             )

    %{
      operator: operator,
      commitment: commitment,
      task: task,
      reader:
        member!(operator, "Erased reader #{unique}", [
          {Task, :read, :global},
          {EventLog, :read, :global}
        ])
    }
  end

  test "a derived label names the erased antecedent, and the write history survives", %{
    task: task,
    commitment: commitment,
    reader: reader
  } do
    {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "label")

    derived =
      Enum.find(explanation.steps, fn step ->
        step.relation == :was_derived_from and step.antecedent.attribute == "commitment"
      end)

    assert derived, "label did not name its commitment"

    # The derivation's value is the label's, never the antecedent's, and no
    # step carries the shredded value or the marker that stands in for it.
    refute inspect(explanation) =~ commitment
    refute inspect(explanation) =~ "[shredded]"

    # The antecedent was dispatched: an erased gap of its address...
    assert [%{kind: :erased} = gap] =
             Enum.filter(explanation.gaps, &(&1.kind == :erased))

    assert gap.of.attribute == "commitment"
    # ...a plain shred with no erasure receipt: nothing says one exists.
    assert is_nil(gap.receipt)

    # The write history is not erased: the audit explainer still answers for
    # the commitment, at :record granularity, with no value.
    generated =
      Enum.find(explanation.steps, fn step ->
        step.relation == :was_generated_by and step.entity.attribute == "commitment"
      end)

    assert generated, "the audit explainer stopped answering for the erased commitment"
    assert generated.granularity == :record
    assert is_nil(generated.value)
  end

  test "a reader without receipt access sees erased and no receipt either way", %{
    task: task,
    operator: operator
  } do
    without =
      member!(operator, "No receipts #{System.unique_integer([:positive])}", [
        {Task, :read, :global},
        {EventLog, :read, :global}
      ])

    with_access =
      member!(operator, "Receipts #{System.unique_integer([:positive])}", [
        {Task, :read, :global},
        {EventLog, :read, :global},
        {PersonErasure, :read, :global}
      ])

    {:ok, %{explanation: without_answer}} = explain(without, "task", task.id, "label")
    {:ok, %{explanation: with_answer}} = explain(with_access, "task", task.id, "label")

    for explanation <- [without_answer, with_answer] do
      assert [%{kind: :erased, receipt: nil}] =
               Enum.filter(explanation.gaps, &(&1.kind == :erased))
    end

    # No erasure was recorded, so even a reader of receipts learns nothing of one.
    assert PersonErasure |> Ash.read!(tenant: operator.tenant, authorize?: false) == []
  end

  defp explain(ctx, type, id, attribute) do
    Provenance.explain("#{Provenance.base()}/#{type}/#{id}##{attribute}",
      actor: ctx.actor,
      tenant: ctx.tenant
    )
  end

  describe "an erased person" do
    # A person erasure blanks the plaintext `name` on the row, so it is plain
    # nil, not a `Shredded`. Only a person erasure blanks it, so a nil reads
    # as erased only when the reader may read the erase's receipt.
    setup do
      operator = tenant!(operator?: true)
      unique = System.unique_integer([:positive])
      email = "erased-person-#{unique}@example.test"
      name = "Erased Person #{unique}"

      reader =
        member!(operator, "Erased reader #{unique}", [
          {AshEnterprise.Canonical.Person, :read, :basic},
          {EventLog, :read, :global},
          {PersonErasure, :read, :global},
          {AshEnterprise.Accounts.User, :read, :global}
        ])

      person = person!(reader, email, name)

      assert {:ok, receipt} =
               Erasure.erase_person(email, email, "test",
                 actor: operator.actor,
                 tenant: operator.tenant
               )

      %{reader: reader, person: person, email: email, name: name, receipt: receipt}
    end

    test "a blanked name reads as erased with the receipt, and the sealed address keeps its own",
         %{
           reader: reader,
           person: person,
           email: email,
           name: name,
           receipt: receipt
         } do
      {:ok, %{explanation: explanation}} = explain(reader, "person", person.id, "name")

      assert [%{kind: :erased, receipt: name_receipt}] =
               Enum.filter(explanation.gaps, &(&1.kind == :erased))

      assert name_receipt == "person_erasure:" <> to_string(receipt.id)

      {:ok, %{explanation: email_explanation}} = explain(reader, "person", person.id, "email")

      assert [%{kind: :erased, receipt: email_receipt}] =
               Enum.filter(email_explanation.gaps, &(&1.kind == :erased))

      assert email_receipt == name_receipt

      # Neither answer carries the name or the address it erased.
      for answer <- [explanation, email_explanation] do
        refute inspect(answer) =~ name
        refute inspect(answer) =~ email
      end
    end

    test "a reader who may not read the receipt is told nothing of the erase", %{
      operator: operator
    } do
      unique = System.unique_integer([:positive])

      blind =
        member!(operator, "No receipts #{System.unique_integer([:positive])}", [
          {AshEnterprise.Canonical.Person, :read, :basic},
          {EventLog, :read, :global},
          {AshEnterprise.Accounts.User, :read, :global}
        ])

      # A person row is owner-only, so the member who reads the answer owns it.
      email = "blinded-person-#{unique}@example.test"
      blind_person = person!(blind, email, "Blinded Person #{unique}")

      assert {:ok, _receipt} =
               Erasure.erase_person(email, email, "test",
                 actor: operator.actor,
                 tenant: operator.tenant
               )

      result = explain(blind, "person", blind_person.id, "name")
      assert {:ok, %{explanation: explanation}} = result

      assert Enum.filter(explanation.gaps, &(&1.kind == :erased)) == []
      refute inspect(result) =~ "person_erasure:"
      refute inspect(result) =~ "Blinded Person #{unique}"
      refute inspect(result) =~ email
    end

    test "a person still standing reads no erased gap", %{reader: reader} do
      unique = System.unique_integer([:positive])

      live =
        person!(reader, "standing-person-#{unique}@example.test", "Standing Person #{unique}")

      {:ok, %{explanation: explanation}} = explain(reader, "person", live.id, "name")

      assert Enum.filter(explanation.gaps, &(&1.kind == :erased)) == []
    end
  end
end
