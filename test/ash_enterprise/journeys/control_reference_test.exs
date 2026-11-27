defmodule AshEnterprise.Journeys.ControlReferenceTest do
  @moduledoc """
  `journey:<id>` references in `docs/controls.json` (`AshEnterprise.Journeys.ControlReference`),
  as `mix ash_compliance.controls.check` resolves them: a journey proves a row only while
  it is declared and its approved run in every locale still proves it.

  The broken cases run the check on the committed control file under a copy of the
  project's `priv/journeys/` that is missing, or whose lock no longer matches the
  declaration.
  """

  # Not async: one test swaps the Mix shell, which is global.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias AshCompliance.Ownership.{Check, Criteria, Resolver}
  alias AshEnterprise.Journeys.ControlReference
  alias AshJourneys.Lock

  @id "revoke_a_leavers_access"
  @ref "journey:" <> @id
  @controls "docs/controls.json"

  defp problems(file, root) do
    Check.run(file,
      categories: Criteria.categories(),
      root: root,
      require_producer_proof: true
    )
  end

  defp for_row(problems, id), do: Enum.filter(problems, &(&1.criterion == id))

  # The committed control file with CC6.2 naming `ref` as producer and test.
  defp controls_naming(dir, ref) do
    document = @controls |> File.read!() |> Jason.decode!()

    criteria =
      Enum.map(document["criteria"], fn
        %{"id" => "CC6.2"} = row -> %{row | "evidence_producer" => ref, "test_ref" => ref}
        row -> row
      end)

    path = Path.join(dir, "controls.json")
    File.write!(path, Jason.encode!(%{document | "criteria" => criteria}))
    path
  end

  # The project's approved runs under `dir`, with the lock edited by `fun`.
  defp journeys_under(dir, fun \\ & &1) do
    File.mkdir_p!(Path.join(dir, "priv"))
    File.cp_r!("priv/journeys", Path.join(dir, "priv/journeys"))
    lock = dir |> Lock.path() |> File.read!() |> Jason.decode!()
    File.write!(Lock.path(dir), Jason.encode!(fun.(lock)))
    dir
  end

  describe "the committed control file" do
    test "CC6.2 and CC6.3 name the offboarding journey as producer and test" do
      rows = @controls |> File.read!() |> Jason.decode!() |> Map.fetch!("criteria")

      for id <- ["CC6.2", "CC6.3"] do
        assert %{"evidence_producer" => @ref, "test_ref" => @ref} =
                 Enum.find(rows, &(&1["id"] == id))
      end
    end

    test "the journey resolves and proves both rows, with producer proof required" do
      problems = problems(@controls, File.cwd!())

      assert for_row(problems, "CC6.2") == []
      assert for_row(problems, "CC6.3") == []
      assert Resolver.resolve(@ref, File.cwd!()) == :ok
    end
  end

  describe "the check fails" do
    test "on a journey no module declares", %{tmp_dir: dir} do
      file = controls_naming(dir, "journey:no_such_journey")

      assert [%{code: :unwired_platform_row, message: message}] =
               for_row(problems(file, File.cwd!()), "CC6.2") |> Enum.uniq_by(& &1.code)

      assert message =~ "journey no_such_journey is not declared"
    end

    test "on a journey with no approved run", %{tmp_dir: dir} do
      assert [%{code: :unwired_platform_row, message: message} | _] =
               for_row(problems(@controls, dir), "CC6.2")

      assert message =~ "journey #{@id}: en is unapproved"
      assert message =~ "fr is unapproved"
    end

    test "on a stale journey: its declaration is not the one approved", %{tmp_dir: dir} do
      root =
        journeys_under(dir, fn lock ->
          put_in(lock, ["journeys", @id, "fr", "hash"], String.duplicate("0", 64))
        end)

      assert [%{code: :unwired_platform_row, message: message} | _] =
               for_row(problems(@controls, root), "CC6.2")

      assert message =~ "journey #{@id}: fr is stale"
      refute message =~ "en is"
    end

    test "on a stale journey: the lock pins another browser build", %{tmp_dir: dir} do
      root =
        journeys_under(dir, fn lock ->
          put_in(lock, ["browser", "version"], "1.0.0")
        end)

      assert {:error, message} = ControlReference.resolve(@id, root)
      assert message =~ "en is stale"
      assert message =~ "fr is stale"
    end

    test "when the journey does not name the criterion it is the producer for" do
      assert ControlReference.proves_producer(@id, "CC6.2") == :ok
      assert ControlReference.proves_producer(@id, "CC6.3") == :ok

      assert {:error, "journey #{@id} does not name CC6.1 in its metadata controls"} =
               ControlReference.proves_producer(@id, "CC6.1")
    end
  end

  test "an unchanged copy of the approved runs resolves", %{tmp_dir: dir} do
    assert ControlReference.resolve(@id, journeys_under(dir)) == :ok
  end

  test "the task reports a broken journey reference by criterion", %{tmp_dir: dir} do
    file = controls_naming(dir, "journey:no_such_journey")
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.AshCompliance.Controls.Check.run([
      "--file",
      file,
      "--report",
      "--require-producer-proof",
      "--categories",
      "security"
    ])

    lines = collect_output([])

    assert Enum.any?(
             lines,
             &(&1 =~ "CC6.2  [unwired_platform_row]" and &1 =~ "journey no_such_journey")
           )
  end

  defp collect_output(lines) do
    receive do
      {:mix_shell, :info, [line]} -> collect_output([line | lines])
    after
      0 -> Enum.reverse(lines)
    end
  end
end
