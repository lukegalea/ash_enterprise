defmodule AshEnterprise.Provenance.FacadeTest do
  @moduledoc """
  The ontology-facade explainer (ADR 0083, decision 8): `explain` of a facade
  value steps through the lens to the source value, then on through the source's
  own explainers, as the reader, and nothing in it is more than the reader could
  read one record at a time.

  The refusals come first: a facade is an easy way to read around a grant, and
  an explanation is an easy way to name a row the reader may not see.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.Credential
  alias AshEnterprise.Provenance
  alias AshEnterprise.Provenance.{Explainers, Walk}
  alias AshEnterprise.Test.Facades.{Licence, Registry, WorkItem}
  alias AshProvenance.Address

  @number_key "AshEnterprise.Credentialing.Credential#number"

  setup do
    %{admin: tenant!()}
  end

  describe "a value read through a lens" do
    test "is derived from the source value, which the source's own explainers then answer", %{
      admin: admin
    } do
      reader = auditor(admin)
      task = capture!(reader, "Send the deck")

      {:ok, %{explanation: explanation}} = explain(reader, "work_item", task.id, "name")

      derived = Enum.find(explanation.steps, &(&1.relation == :was_derived_from))
      assert iri(derived.entity) == "#{Provenance.base()}/work_item/#{task.id}#name"
      assert iri(derived.antecedent) == "#{Provenance.base()}/task/#{task.id}#title"
      assert derived.granularity == :value
      assert derived.plan.key == "work_item"
      assert derived.plan.version == AshStrangler.Facade.Info.mapping_version(WorkItem)

      # The hop after the lens is the source's: the write that set the title.
      generated = Enum.find(explanation.steps, &(&1.relation == :was_generated_by))
      assert iri(generated.entity) == "#{Provenance.base()}/task/#{task.id}#title"
      assert generated.summary == "create capture"
      assert explanation.gaps == []
    end

    test "a decode is explained through the column it reads", %{admin: admin} do
      reader = auditor(admin)
      task = capture!(reader, "Decide")

      {:ok, %{explanation: explanation}} = explain(reader, "work_item", task.id, "state")

      derived = Enum.find(explanation.steps, &(&1.relation == :was_derived_from))
      assert derived.antecedent.attribute == "status"
      assert derived.summary == "through a decode lens"
    end

    test "a reader without the audit grant gets the lens and the record columns", %{admin: admin} do
      reader = member!(admin, "No audit", [{Task, :read, :global}, {User, :read, :global}])
      task = capture!(reader, "Book the venue")

      {:ok, %{explanation: explanation}} = explain(reader, "work_item", task.id, "name")

      assert Enum.any?(explanation.steps, &(&1.relation == :was_derived_from))
      refute Enum.any?(explanation.steps, &(&1.relation == :was_generated_by))
      assert Enum.any?(explanation.steps, &(&1.relation == :was_attributed_to))
    end

    test "is dispatched by what the resource is: the facade explainer first, then the generic ones" do
      generic = [Explainers.Derived, Explainers.Audit, Explainers.RecordColumns]

      assert Provenance.Registry.explainers_for(WorkItem, :name) == [Explainers.Facade | generic]
      assert Provenance.Registry.explainers_for(Licence, :kind) == [Explainers.Facade | generic]
      assert Provenance.Registry.explainers_for(Task, :title) == generic
    end
  end

  describe "an unreadable subject" do
    test "is not found, the same way whatever hides it", %{admin: admin} do
      owner = auditor(admin)
      task = capture!(owner, "Not the stranger's")
      stranger = member!(admin, "Stranger", [])

      missing_id = Ash.UUID.generate()

      assert {:error, %Ash.Error.Query.NotFound{} = missing} =
               explain(stranger, "work_item", missing_id, "name")

      assert {:error, %Ash.Error.Query.NotFound{} = hidden} =
               explain(stranger, "work_item", task.id, "name")

      assert mask(missing, missing_id) == mask(hidden, task.id)
    end
  end

  describe "a secured column of the source" do
    setup %{admin: admin} do
      clinic =
        Credentialing.register_clinic!(
          "Facade explain #{System.unique_integer([:positive])}",
          as(admin)
        )

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

      number = "SYN-#{System.unique_integer([:positive])}"

      credential =
        Credential
        |> Ash.Changeset.for_create(
          :record,
          %{
            kind: :licence,
            number: number,
            expires_on: ~D[2030-01-31],
            clinician_id: clinician.id
          },
          as(admin)
        )
        |> Ash.create!()

      %{credential: credential, number: number}
    end

    test "is an unreadable gap for a reader without its grant, and names no source row", ctx do
      reader =
        member!(ctx.admin, "Reviewer", [
          {Credential, :read, :global},
          {EventLog, :read, :global},
          {User, :read, :global}
        ])

      {:ok, %{explanation: explanation} = result} =
        explain(reader, "licence", ctx.credential.id, "licence_number")

      assert explanation.steps == []
      assert [%{kind: :unreadable, receipt: nil, summary: nil, at: nil}] = explanation.gaps
      refute inspect(result) =~ "credential/"
      refute inspect(result) =~ "#number"
      refute inspect(result) =~ ctx.number
    end

    test "is named by the step for the holder of its grant, and never dispatched or shown", ctx do
      holder =
        member!(ctx.admin, "Holder", [
          {Credential, :read, :global},
          {@number_key, :read, :global},
          {EventLog, :read, :global},
          {User, :read, :global}
        ])

      {:ok, %{explanation: explanation} = result} =
        explain(holder, "licence", ctx.credential.id, "licence_number")

      assert [step] = explanation.steps
      assert step.relation == :was_derived_from

      assert iri(step.antecedent) ==
               "#{Provenance.base()}/credential/#{ctx.credential.id}#number"

      # What the log or the record columns say about the secured column is what its
      # grant withholds: the walk stops at the step.
      assert step.value == nil
      refute inspect(result) =~ ctx.number
      assert explanation.gaps == []
    end
  end

  describe "a source row the reader may no longer read" do
    test "is an unreadable gap and no step, never the source's own refusal", %{admin: admin} do
      reader = auditor(admin)
      task = capture!(reader, "Read a moment ago")

      address =
        Address.new!(
          base: Provenance.base(),
          type: "work_item",
          id: to_string(task.id),
          attribute: "name"
        )

      {:ok, subject} = Walk.read_subject(address, WorkItem, ctx(reader))

      # The facade row was read as the reader; the source read is another
      # reader's, who holds no grant on it.
      stranger = member!(admin, "Stranger", [])

      assert {:ok, answer} = Explainers.Facade.explain(subject, ctx(stranger))
      assert answer.steps == []
      assert answer.antecedents == []
      assert [%{kind: :unreadable, receipt: nil, summary: nil}] = answer.gaps
      refute inspect(answer) =~ "task/"
    end
  end

  test "a resource that is not a facade passes", %{admin: admin} do
    reader = auditor(admin)
    task = capture!(reader, "Not a facade")

    address =
      Address.new!(
        base: Provenance.base(),
        type: "task",
        id: to_string(task.id),
        attribute: "title"
      )

    {:ok, subject} = Walk.read_subject(address, Task, ctx(reader))
    assert :pass = Explainers.Facade.explain(subject, ctx(reader))
  end

  test "a facade address with no attribute passes to the generic explainers", %{admin: admin} do
    reader = auditor(admin)
    task = capture!(reader, "Whole row")

    address = Address.new!(base: Provenance.base(), type: "work_item", id: to_string(task.id))

    {:ok, subject} = Walk.read_subject(address, WorkItem, ctx(reader))
    assert :pass = Explainers.Facade.explain(subject, ctx(reader))
  end

  defp auditor(admin) do
    member!(admin, "Auditor #{System.unique_integer([:positive])}", [
      {Task, :read, :global},
      {EventLog, :read, :global},
      {User, :read, :global}
    ])
  end

  defp as(member), do: [actor: member.actor, tenant: member.tenant]

  defp ctx(member) do
    %{
      actor: member.actor,
      tenant: member.tenant,
      base: Provenance.base(),
      registry: Registry,
      cache: %{}
    }
  end

  defp explain(member, type, id, attribute) do
    Walk.explain(
      "#{Provenance.base()}/#{type}/#{id}##{attribute}",
      [registry: Registry] ++ as(member)
    )
  end

  defp capture!(member, title), do: Task.capture!(title, %{}, as(member))

  defp iri(address), do: Address.to_iri(address)

  # The id the address named, masked: only the address was given, so the two
  # refusals may not differ in anything else.
  defp mask(error, id), do: error |> Exception.message() |> String.replace(id, "<id>")
end
