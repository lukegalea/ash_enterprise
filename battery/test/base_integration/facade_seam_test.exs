defmodule Battery.Integration.FacadeSeamTest do
  @moduledoc """
  Scenario — facade over a canonical resource (ash_strangler): facades give
  a different vocabulary to an owned source's rows without storing anything
  of their own, every read runs as the caller, and every write is one named
  source action run as the caller — the source's policies decide. A card
  facade over the guarded credential (the read half); a work-item facade
  over the temporal task with the write half, and a row facade over the
  work-item — a two-hop chain.

  Asserted here: the secured column (a viewer without the grant reads
  `%Ash.ForbiddenField{}` for the number and for anything computed from it,
  a filter on the guarded number matches nothing, a granted actor reads in
  full, and no actor is no value); the compile-time refusal of a write
  through a read-only lens, quoting the lens's declared reason, with a
  control probe identical but for the write compiling without it; the
  write's negatives (a guarded write returns the source's own message with
  the row unchanged and no event row, an anonymous write is refused, a
  write carrying `as_of` is refused before anything runs, an unknown id is
  not found); the audit invariant — one event row per write on the source,
  none on a facade, and a facade read adds none; `as_of` reading through
  both hops; the hop chain with one version per hop; the three writes doing what they say; and the
  decode on reads and on filters.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  require Ash.Query

  alias Battery.Canonical.{Credential, CredentialCard, Task, WorkItem, WorkItemRow}
  alias Battery.Events.EventLog

  @facades [
    Battery.Canonical.CredentialCard,
    Battery.Canonical.WorkItem,
    Battery.Canonical.WorkItemRow
  ]

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)
    Enum.each([Task, Credential, EventLog], &Battery.Repo.delete_all/1)

    viewer = %{id: System.unique_integer([:positive]), credential_access?: false}
    granted = %{id: System.unique_integer([:positive]), credential_access?: true}

    %{viewer: viewer, granted: granted}
  end

  describe "secured column" do
    test "a viewer without the grant reads forbidden fields, and a filter on the guarded number matches nothing",
         %{
           viewer: viewer
         } do
      n = System.unique_integer([:positive])
      card_credential!(n)

      [card] =
        CredentialCard
        |> Ash.read!(actor: viewer, authorize?: true)

      assert %Ash.ForbiddenField{field: :number} = card.number
      # Never a computed value from a forbidden part.
      assert %Ash.ForbiddenField{field: :display} = card.display

      assert [] =
               CredentialCard
               |> Ash.Query.filter(number == ^"N-#{n}")
               |> Ash.read!(actor: viewer, authorize?: true)
    end

    test "a granted actor reads the number and the display in full", %{granted: granted} do
      n = System.unique_integer([:positive])
      card_credential!(n)

      [card] =
        CredentialCard
        |> Ash.read!(actor: granted, authorize?: true)

      assert card.number == "N-#{n}"
      assert card.display == "holder #{n} N-#{n}"
    end

    test "a read with no actor and authorization on is a forbidden error or no rows, never a value" do
      card_credential!(System.unique_integer([:positive]))

      read =
        CredentialCard
        |> Ash.read(authorize?: true)

      assert match?({:error, _}, read) or read == {:ok, []}
    end
  end

  describe "read-only writes" do
    test "a write through a read-only lens refuses to compile, quoting the lens's declared reason, and a control probe without the write compiles clean" do
      suffix = System.unique_integer([:positive])
      probe = Module.concat(["ProbeFacadeReadsState_#{suffix}"])
      control = Module.concat(["ProbeFacadeReadsStateControl_#{suffix}"])

      stderr =
        capture_io(:stderr, fn ->
          Code.compile_string(probe_facade_source(suffix))
        end)

      # Spark's verifier reports the refusal as a compile diagnostic, and the
      # diagnostic must name the lens's declared reason, never write it anyway.
      assert stderr =~ "This probe reads state, it does not decide it."

      control_stderr =
        capture_io(:stderr, fn ->
          Code.compile_string(control_probe_source(suffix))
        end)

      refute control_stderr =~ "This probe reads state, it does not decide it."

      Enum.each([probe, control], fn module ->
        :code.purge(module)
        :code.delete(module)
      end)
    end
  end

  describe "guarded writes" do
    test "a finish on a done task returns the source's own message, leaves the row and the log alone" do
      actor = %{id: System.unique_integer([:positive])}
      task = task!(title: "already done", status: :done)
      before = all_events()

      {:error, error} =
        Ash.ActionInput.for_action(WorkItem, :finish, %{id: task.id},
          actor: actor,
          authorize?: true
        )
        |> Ash.run_action()

      assert Exception.message(error) =~ "only an open task can be completed"
      assert source_state(task.id) == :done
      assert all_events() == before
      assert facade_events() == []
    end

    test "a write with no actor and authorization on is refused and writes nothing" do
      task = task!(title: "anonymous")
      before = all_events()

      {:error, error} =
        Ash.ActionInput.for_action(WorkItem, :finish, %{id: task.id}, authorize?: true)
        |> Ash.run_action()

      assert match?(%Ash.Error.Forbidden{}, error)
      assert source_state(task.id) == :open
      assert all_events() == before
      assert facade_events() == []
    end

    test "a write carrying as_of is refused before anything runs" do
      task = task!(title: "pinned")
      instant = DateTime.add(DateTime.utc_now(), -3_600)
      before = all_events()

      {:error, error} =
        Ash.ActionInput.for_action(WorkItem, :finish, %{id: task.id}, as_of: instant)
        |> Ash.run_action()

      # The facade's own refusal, quoting its rule — not a source error.
      assert Exception.message(error) =~ "a facade write takes effect now"
      assert Exception.message(error) =~ "as_of"
      assert source_state(task.id) == :open
      assert all_events() == before
      assert facade_events() == []
    end

    test "a write to an id that does not exist is not found and writes nothing" do
      actor = %{id: System.unique_integer([:positive])}
      before = all_events()

      {:error, error} =
        Ash.ActionInput.for_action(WorkItem, :finish, %{id: Ash.UUID.generate()},
          actor: actor,
          authorize?: true
        )
        |> Ash.run_action()

      assert match?(%{errors: [%Ash.Error.Query.NotFound{} | _]}, error)
      assert all_events() == before
      assert facade_events() == []
    end
  end

  describe "audit" do
    test "a facade read adds no event-log row, and no facade module ever appears in the log" do
      card_credential!(System.unique_integer([:positive]))
      granted = %{id: System.unique_integer([:positive]), credential_access?: true}

      CredentialCard
      |> Ash.read!(actor: granted, authorize?: true)

      CredentialCard
      |> Ash.read!(actor: granted, authorize?: true)

      assert events_for(Battery.Canonical.CredentialCard) == []

      facade_rows =
        EventLog
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(&1.resource in @facades))

      assert facade_rows == []
    end

    test "one event row per write, on the source with the source action's name, none on a facade" do
      actor = %{id: System.unique_integer([:positive])}
      task = task!(title: "audited")

      before = %{
        complete: count_events(Task, :complete),
        set_estimate: count_events(Task, :set_estimate),
        retitle: count_events(Task, :retitle)
      }

      assert before == %{complete: 0, set_estimate: 0, retitle: 0}

      for {action, input} <- [
            {:finish, %{id: task.id}},
            {:set_estimate, %{id: task.id, effort_minutes: 30}},
            {:retitle, %{id: task.id, title: "audited twice"}}
          ] do
        assert {:ok, _} =
                 Ash.ActionInput.for_action(WorkItem, action, input,
                   actor: actor,
                   authorize?: true
                 )
                 |> Ash.run_action()
      end

      assert count_events(Task, :complete) == 1
      assert count_events(Task, :set_estimate) == 1
      assert count_events(Task, :retitle) == 1
      assert facade_events() == []
    end
  end

  describe "time travel" do
    test "as_of reads pass through one hop, and a read with no as_of is now" do
      now = DateTime.utc_now()
      t0 = DateTime.add(now, -30)
      t1 = DateTime.add(now, -20)

      task =
        Ash.Changeset.for_create(Task, :create, %{title: "old name"},
          as_of: t0,
          authorize?: false
        )
        |> Ash.create!()

      Ash.Changeset.for_update(task, :retitle, %{title: "new name"},
        as_of: t1,
        authorize?: false
      )
      |> Ash.update!()

      value_at = fn facade, field, as_of ->
        facade
        |> Ash.Query.filter(id == ^task.id)
        |> Ash.read!(as_of: as_of, authorize?: false)
        |> case do
          [] -> nil
          [row] -> Map.fetch!(row, field)
        end
      end

      assert value_at.(WorkItem, :title, t0) == "old name"
      assert value_at.(WorkItem, :title, t1) == "new name"
      # Before the row began, the id is absent — never a future value.
      assert value_at.(WorkItem, :title, DateTime.add(t0, -5)) == nil
      assert value_at.(WorkItem, :title, nil) == "new name"
    end

    test "as_of reads pass through the second hop too" do
      now = DateTime.utc_now()
      t0 = DateTime.add(now, -30)
      t1 = DateTime.add(now, -20)

      task =
        Ash.Changeset.for_create(Task, :create, %{title: "old name"},
          as_of: t0,
          authorize?: false
        )
        |> Ash.create!()

      Ash.Changeset.for_update(task, :retitle, %{title: "new name"},
        as_of: t1,
        authorize?: false
      )
      |> Ash.update!()

      label_at = fn as_of ->
        WorkItemRow
        |> Ash.Query.filter(id == ^task.id)
        |> Ash.read!(as_of: as_of, authorize?: false)
        |> case do
          [] -> nil
          [row] -> row.label
        end
      end

      assert label_at.(t0) == "old name"
      assert label_at.(t1) == "new name"
      assert label_at.(nil) == "new name"
    end
  end

  describe "two hops" do
    test "the hop chain from the row facade runs through the work-item to the owned task, one version per hop" do
      hops = AshStrangler.Facade.Info.hops(WorkItemRow)

      assert [
               %{kind: :facade, resource: WorkItemRow, source: WorkItem},
               %{kind: :facade, resource: WorkItem, source: Task},
               %{kind: :owned, resource: Task, source: nil}
             ] = hops

      assert AshStrangler.Facade.Info.mapping_versions(WorkItemRow) ==
               Enum.map(hops, & &1.mapping_version)
    end

    test "a read through the row facade returns the label" do
      task = task!(title: "label me")

      assert [row] =
               WorkItemRow
               |> Ash.Query.filter(id == ^task.id)
               |> Ash.read!(authorize?: false)

      assert row.label == "label me"
    end
  end

  describe "writes" do
    test "finish moves the source row to done and returns the finished facade record" do
      actor = %{id: System.unique_integer([:positive])}
      task = task!(title: "open work")

      {:ok, record} =
        Ash.ActionInput.for_action(WorkItem, :finish, %{id: task.id},
          actor: actor,
          authorize?: true
        )
        |> Ash.run_action()

      assert %WorkItem{} = record
      assert record.state == :finished
      assert source_state(task.id) == :done
    end

    test "set_estimate stores effort_minutes as the source's estimated_minutes" do
      actor = %{id: System.unique_integer([:positive])}
      task = task!(title: "estimated")

      {:ok, record} =
        Ash.ActionInput.for_action(WorkItem, :set_estimate, %{id: task.id, effort_minutes: 45},
          actor: actor,
          authorize?: true
        )
        |> Ash.run_action()

      assert record.effort_minutes == 45
      assert source_task!(task.id).estimated_minutes == 45
    end

    test "retitle renames the source row" do
      actor = %{id: System.unique_integer([:positive])}
      task = task!(title: "before the rename")

      {:ok, record} =
        Ash.ActionInput.for_action(WorkItem, :retitle, %{id: task.id, title: "after the rename"},
          actor: actor,
          authorize?: true
        )
        |> Ash.run_action()

      assert record.title == "after the rename"
      assert source_task!(task.id).title == "after the rename"
    end
  end

  describe "the decode" do
    test "an open task reads as new, and a filter on the finished state finds only the done rows" do
      open = task!(title: "open one")
      done = task!(title: "done one", status: :done)

      states =
        WorkItem
        |> Ash.read!(authorize?: false)
        |> Map.new(&{&1.id, &1.state})

      assert states[open.id] == :new
      assert states[done.id] == :finished

      assert [finished] =
               WorkItem
               |> Ash.Query.filter(state == :finished)
               |> Ash.read!(authorize?: false)

      assert finished.id == done.id
    end
  end

  # A probe facade over the task: `state` is a read-only lens over `status`,
  # and the write declares it in `sets:`. The verifiers must refuse the
  # declaration, naming the reason the lens gave — never writing it anyway.
  # Every attribute it maps is declared on the probe, so the one refusal is
  # the read-only write.
  defp probe_facade_source(suffix) do
    probe_module = "ProbeFacadeReadsState_#{suffix}"

    """
    defmodule #{probe_module} do
      use Ash.Resource,
        domain: Battery.Domain,
        data_layer: Ash.DataLayer.Simple,
        extensions: [AshStrangler.Facade]

      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true

        attribute :state, :atom,
          public?: true,
          constraints: [one_of: [:new, :finished, :cancelled]]

        attribute :title, :string, public?: true
        attribute :effort_minutes, :integer, public?: true
      end

      facade do
        source Battery.Canonical.Task

        map :id, from: :id

        map :state,
          from: expr(status),
          read_only?: true,
          because: "This probe reads state, it does not decide it."

        map :title, from: :title
        map :effort_minutes, from: :estimated_minutes

        hide :internal_notes, because: "Not part of this vocabulary."
        defer :legacy_ref
        defer :valid_at

        write :finish, via: :complete, sets: [state: :finished]
      end
    end
    """
  end

  # The control probe: identical, but for the write line. It must compile,
  # and say nothing about deciding state.
  defp control_probe_source(suffix) do
    probe_module = "ProbeFacadeReadsStateControl_#{suffix}"

    """
    defmodule #{probe_module} do
      use Ash.Resource,
        domain: Battery.Domain,
        data_layer: Ash.DataLayer.Simple,
        extensions: [AshStrangler.Facade]

      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true

        attribute :state, :atom,
          public?: true,
          constraints: [one_of: [:new, :finished, :cancelled]]

        attribute :title, :string, public?: true
        attribute :effort_minutes, :integer, public?: true
      end

      facade do
        source Battery.Canonical.Task

        map :id, from: :id

        map :state,
          from: expr(status),
          read_only?: true,
          because: "This probe reads state, it does not decide it."

        map :title, from: :title
        map :effort_minutes, from: :estimated_minutes

        hide :internal_notes, because: "Not part of this vocabulary."
        defer :legacy_ref
        defer :valid_at
      end
    end
    """
  end

  defp task!(attrs) do
    Ash.create!(Ash.Changeset.for_create(Task, :create, attrs, authorize?: false))
  end

  defp card_credential!(n) do
    Ash.create!(
      Ash.Changeset.for_create(
        Credential,
        :create,
        %{holder: "holder #{n}", number: "N-#{n}"},
        authorize?: false
      )
    )
  end

  defp source_task!(id) do
    Task
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false)
  end

  defp source_state(id) do
    case source_task!(id) do
      nil -> nil
      task -> task.status
    end
  end

  defp all_events do
    EventLog
    |> Ash.read!(authorize?: false)
  end

  defp count_events(resource, action) do
    all_events()
    |> Enum.count(&(&1.resource == resource and &1.action == action))
  end

  defp facade_events do
    all_events()
    |> Enum.filter(&(&1.resource in @facades))
  end

  defp events_for(resource) do
    EventLog
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.resource == resource))
  end
end
