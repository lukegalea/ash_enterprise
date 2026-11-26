defmodule AshEnterprise.Provenance.ExplainTest do
  @moduledoc """
  `AshEnterprise.Provenance.explain/2` (ADR 0078), through the code interface
  only: what a readable value answers, and what a reader may not learn.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, person!: 3]

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.Credential
  alias AshEnterprise.Provenance

  @number_key "AshEnterprise.Credentialing.Credential#number"

  setup do
    %{admin: tenant!()}
  end

  describe "the audit answer" do
    test "a title a person set names the write, its actor and its correlation id", %{admin: admin} do
      writer = member!(admin, "Writer", [])

      reader =
        member!(admin, "Reader", [
          {Task, :read, :global},
          {EventLog, :read, :global},
          {User, :read, :global}
        ])

      task = capture!(writer, "Send Dana the Q3 deck")

      {:ok, %{explanation: explanation, correlation_ids: correlation_ids}} =
        explain(reader, "task", task.id, "title")

      generated = step(explanation, :was_generated_by)
      assert generated.granularity == :value
      assert generated.summary == "create capture"
      # Not recorded on this write, and never read as live.
      assert generated.execution_context == nil

      associated = step(explanation, :was_associated_with)
      assert associated.agent_label == writer.email
      assert associated.activity == generated.activity

      event = Audit.latest_event_for_record!(to_string(Task), task.id, "title", as(reader))
      assert Map.fetch!(correlation_ids, generated.activity) == event.correlation_id
    end

    test "a reader without the audit grant gets the record columns, and nothing from the log", %{
      admin: admin
    } do
      # The task grant is the reader's own reading of the row and the user
      # grant labels the creator; the point is that no audit grant reaches
      # the log.
      me = member!(admin, "No audit", [{Task, :read, :global}, {User, :read, :global}])
      task = capture!(me, "Book the venue")

      {:ok, %{explanation: explanation, correlation_ids: correlation_ids}} =
        explain(me, "task", task.id, "title")

      refute Enum.any?(
               explanation.steps,
               &(&1.relation in [:was_generated_by, :was_associated_with])
             )

      assert correlation_ids == %{}

      assert [created] = Enum.filter(explanation.steps, &(&1.relation == :was_attributed_to))
      assert created.granularity == :record
      assert created.summary == "created"
      assert created.agent_label == me.email

      # Nothing modified the row yet: a gap, not a step.
      assert Enum.any?(explanation.gaps, &(&1.kind == :not_recorded))
    end

    test "a writer the reader may not read is a person, never an id", %{admin: admin} do
      writer = member!(admin, "Writer", [])
      task = capture!(writer, "Two tickets for Friday")

      # The audit grant reaches the log; without a grant on users the label is
      # all the reader gets.
      reader =
        member!(admin, "Auditor", [{Task, :read, :global}, {EventLog, :read, :global}])

      {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

      assert step(explanation, :was_associated_with).agent_label == "a person"
      refute inspect(explanation) =~ writer.user.id
    end
  end

  describe "an unreadable subject" do
    test "is not found, the same way whatever hides it", %{admin: admin} do
      # A task in another tenant: invisible across the tenant boundary.
      elsewhere = tenant!()
      foreign_task = capture!(elsewhere, "Another tenant's item")
      # A member of that tenant with no grants: the same task is hidden by a
      # different mechanism for them.
      foreign_nobody = member!(elsewhere, "No grants", [])

      # A task in the reader's own tenant the reader may not read.
      other = member!(admin, "Someone else", [])
      hidden_task = capture!(other, "Not the reader's item")

      reader = member!(admin, "Nobody special", [])

      missing_id = Ash.UUID.generate()

      missing = explain(reader, "task", missing_id, "title")
      cross_tenant = explain(reader, "task", foreign_task.id, "title")
      unreadable = explain(reader, "task", hidden_task.id, "title")

      for result <- [missing, cross_tenant, unreadable] do
        assert {:error, %Ash.Error.Invalid{}} = result
      end

      # Three reasons a row is not there must read identically: only the
      # address was given, so the answer may not say which refusal it hit.
      # Each case's own id is masked before comparing, and the class-level
      # message (which carries the walk's own stacktrace, naming the caller)
      # is not part of the comparison.
      error_of = fn {:error, error} -> error end

      messages = fn error, id ->
        error.errors
        |> Enum.map(&Exception.message/1)
        |> Enum.map(&String.replace(&1, id, "<id>"))
      end

      assert {:error, without_the_grant} =
               explain(foreign_nobody, "task", foreign_task.id, "title")

      assert messages.(error_of.(missing), missing_id) ==
               messages.(error_of.(cross_tenant), foreign_task.id)

      assert messages.(error_of.(cross_tenant), foreign_task.id) ==
               messages.(error_of.(unreadable), hidden_task.id)

      assert messages.(error_of.(unreadable), hidden_task.id) ==
               messages.(without_the_grant, foreign_task.id)

      for {a, b} <- Enum.zip(error_of.(unreadable).errors, without_the_grant.errors) do
        assert a.class == b.class
      end
    end

    test "an address naming no public value is invalid, whether or not the row exists", %{
      admin: admin
    } do
      person =
        person!(admin, "synthetic-#{System.unique_integer([:positive])}@example.test", "Synth")

      reader = member!(admin, "Nobody special", [])

      sealed = explain(reader, "person", person.id, "encrypted_email")
      assert {:error, %Ash.Error.Invalid{}} = sealed

      assert {:error, no_row} = explain(reader, "person", Ash.UUID.generate(), "encrypted_email")

      assert Enum.map(elem(sealed, 1).errors, &Exception.message/1) ==
               Enum.map(no_row.errors, &Exception.message/1)

      assert {:error, %Ash.Error.Invalid{}} =
               explain(reader, "no_such_type", Ash.UUID.generate(), "title")

      assert {:error, %Ash.Error.Invalid{}} =
               explain(reader, "task", Ash.UUID.generate(), "made_up_field")

      # `as_of` is refused on a resource that is not temporal, never dropped.
      address =
        "#{Provenance.base()}/task/#{Ash.UUID.generate()}?as_of=2026-01-01T00:00:00Z#title"

      assert {:error, %Ash.Error.Invalid{}} = Provenance.explain(address, as(reader))
    end
  end

  describe "a secured column" do
    setup %{admin: admin} do
      clinic =
        Credentialing.register_clinic!("Secured #{System.unique_integer([:positive])}", as(admin))

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
        Credentialing.record_credential!(
          %{
            kind: :licence,
            number: number,
            expires_on: ~D[2030-01-31],
            clinician_id: clinician.id
          },
          as(admin)
        )

      %{credential: credential, number: number}
    end

    test "the column's grant and the audit grant together still get no audit answer", ctx do
      reader =
        member!(ctx.admin, "Column auditor", [
          {Credential, :read, :global},
          {EventLog, :read, :global},
          {@number_key, :read, :global}
        ])

      {:ok, %{explanation: explanation}} =
        explain(reader, "credential", ctx.credential.id, "number")

      refute Enum.any?(
               explanation.steps,
               &(&1.relation in [:was_generated_by, :was_associated_with])
             )

      assert Enum.any?(explanation.steps, &(&1.relation == :was_attributed_to))
      refute inspect(explanation) =~ ctx.number
    end

    test "without the column's grant the shape is the same and the value is masked", ctx do
      with_grant =
        member!(ctx.admin, "Column auditor", [
          {Credential, :read, :global},
          {EventLog, :read, :global},
          {@number_key, :read, :global}
        ])

      without_grant =
        member!(ctx.admin, "Auditor", [{Credential, :read, :global}, {EventLog, :read, :global}])

      {:ok, held} = explain(with_grant, "credential", ctx.credential.id, "number")
      {:ok, withheld} = explain(without_grant, "credential", ctx.credential.id, "number")

      shape = fn %{explanation: explanation} ->
        Enum.map(explanation.steps, &{&1.relation, &1.granularity})
      end

      assert shape.(held) == shape.(withheld)
      assert held.explanation.gaps == withheld.explanation.gaps

      # Wherever a value would appear it is masked or withheld, never shown.
      refute inspect(withheld) =~ ctx.number
      refute inspect(held) =~ ctx.number

      assert Enum.all?(
               steps(held.explanation) ++ steps(withheld.explanation),
               &(&1.value in [nil, :masked])
             )
    end
  end

  describe "a derived value" do
    test "lane names its same-record sources, and they are explained in turn", %{admin: admin} do
      me =
        member!(admin, "Reader", [
          {Task, :read, :global},
          {EventLog, :read, :global},
          {User, :read, :global}
        ])

      task = capture!(me, "Send Dana the Q3 deck")

      {:ok, %{explanation: explanation}} = explain(me, "task", task.id, "lane")

      derived = Enum.filter(explanation.steps, &(&1.relation == :was_derived_from))

      antecedents = Enum.map(derived, & &1.antecedent.attribute)
      assert Enum.sort(antecedents) == ["plan", "status"]
      assert Enum.all?(derived, &(&1.granularity == :value))

      # Each antecedent was dispatched: the write that set it is in the answer.
      for field <- ["status", "plan"] do
        antecedent =
          Enum.find(explanation.steps, fn step ->
            step.relation == :was_generated_by and step.entity.attribute == field
          end)

        assert antecedent, "the walk did not explain #{field}"
      end
    end

    test "a module calculation names what its load reads", %{admin: admin} do
      me = member!(admin, "Reader", [{Task, :read, :global}])
      task = capture!(me, "Send Dana the Q3 deck")

      {:ok, %{explanation: explanation}} = explain(me, "task", task.id, "label")

      derived = Enum.filter(explanation.steps, &(&1.relation == :was_derived_from))

      assert Enum.map(derived, & &1.antecedent.attribute) |> Enum.sort() == [
               "commitment",
               "title"
             ]
    end
  end

  # -- Helpers ------------------------------------------------------------

  defp as(ctx), do: [actor: ctx.actor, tenant: ctx.tenant]

  defp explain(ctx, type, id, attribute) do
    Provenance.explain("#{Provenance.base()}/#{type}/#{id}##{attribute}", as(ctx))
  end

  defp capture!(person, title, extra \\ %{}) do
    Task.capture!(title, extra, as(person))
  end

  defp step(explanation, relation), do: Enum.find(explanation.steps, &(&1.relation == relation))

  defp steps(explanation), do: explanation.steps
end
