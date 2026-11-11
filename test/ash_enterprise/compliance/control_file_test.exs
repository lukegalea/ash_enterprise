defmodule AshEnterprise.Compliance.ControlFileTest do
  @moduledoc """
  `docs/controls.json` against the ownership contract in `ash_compliance`.

  The file is not finished: recurring operating processes, test references and
  evidence producers for many criteria do not exist yet, and the CI step runs
  the checker in `--report` mode for that reason. This suite holds the line
  that does not move:

    * every reference the file makes resolves to something that exists;
    * the file is well formed and covers all 61 criteria exactly once;
    * no row carries a status;
    * the count of still-missing pieces never grows.

  The second half proves the checker is not vacuous here: each way a control
  file can be wrong is fed to it and must be reported.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias AshCompliance.Ownership.{Check, Criteria}

  @file_path "docs/controls.json"

  # Pieces that are allowed to be missing today. Anything else is a defect.
  @not_yet [:no_evidence_producer, :no_process, :no_test_ref, :no_vendor_ref]

  # Lower this when a gap is closed. It must never be raised.
  @known_gaps 101

  defp all_categories, do: Criteria.categories()

  defp problems(path),
    do: Check.run(path, categories: all_categories(), root: File.cwd!())

  defp codes(problems), do: Enum.map(problems, & &1.code)

  defp complete_row(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "class" => "ORG",
        "applicability" => "applicable",
        "frequency" => "annual",
        "owner_role" => "Security Lead",
        "operating_process" => "file:mix.exs",
        "test_ref" => "file:mix.exs"
      },
      overrides
    )
  end

  defp complete_rows(overrides \\ %{}) do
    Enum.map(
      Criteria.in_categories(all_categories()),
      &complete_row(&1.id, overrides[&1.id] || %{})
    )
  end

  defp write!(dir, document) do
    path = Path.join(dir, "controls.json")
    File.write!(path, Jason.encode!(document))
    path
  end

  describe "the committed control file" do
    test "has a row for each of the 61 criteria, once, with nothing malformed" do
      structural = Enum.reject(problems(@file_path), &(&1.code in @not_yet))

      assert structural == []
      assert length(Criteria.in_categories(all_categories())) == 61
    end

    test "points only at modules, tasks and files that exist" do
      unresolved =
        for %{code: code} = problem <- problems(@file_path),
            code in [:unresolvable_producer, :unresolvable_process, :unwired_platform_row],
            do: problem

      assert unresolved == []
    end

    test "no row carries a status" do
      rows = @file_path |> File.read!() |> Jason.decode!() |> Map.fetch!("criteria")

      assert length(rows) == 61
      assert Enum.all?(rows, &(not Map.has_key?(&1, "status")))
    end

    test "the pieces still missing do not grow" do
      gaps = Enum.filter(problems(@file_path), &(&1.code in @not_yet))

      assert length(gaps) <= @known_gaps,
             "#{length(gaps)} gaps, up from #{@known_gaps}. A new row must name its producer, process and test."
    end
  end

  describe "the checker reports each way a control file can be wrong" do
    test "a file that is not there", %{tmp_dir: dir} do
      assert :control_file in codes(problems(Path.join(dir, "absent.json")))
    end

    test "a file that is not JSON", %{tmp_dir: dir} do
      path = Path.join(dir, "controls.json")
      File.write!(path, "{ not json")

      assert :control_file in codes(problems(path))
    end

    test "a file with no criteria at all reports every criterion missing", %{tmp_dir: dir} do
      path = write!(dir, %{"controls" => []})

      missing = Enum.filter(problems(path), &(&1.code == :missing_criterion))
      assert length(missing) == 61
    end

    test "a dropped criterion", %{tmp_dir: dir} do
      rows = Enum.reject(complete_rows(), &(&1["id"] == "CC6.1"))
      path = write!(dir, %{"criteria" => rows})

      assert [%{criterion: "CC6.1", code: :missing_criterion}] =
               Enum.filter(problems(path), &(&1.code == :missing_criterion))
    end

    test "a stored status", %{tmp_dir: dir} do
      path = write!(dir, %{"criteria" => complete_rows(%{"CC6.1" => %{"status" => "compliant"}})})

      assert Enum.any?(problems(path), &(&1.code == :status_stored and &1.criterion == "CC6.1"))
    end

    test "a blank owner role", %{tmp_dir: dir} do
      path = write!(dir, %{"criteria" => complete_rows(%{"CC6.1" => %{"owner_role" => " "}})})

      assert Enum.any?(problems(path), &(&1.code == :no_owner_role and &1.criterion == "CC6.1"))
    end

    test "an unknown class and an unknown frequency", %{tmp_dir: dir} do
      overrides = %{"CC6.1" => %{"class" => "MAGIC"}, "CC6.2" => %{"frequency" => "whenever"}}
      path = write!(dir, %{"criteria" => complete_rows(overrides)})

      found = problems(path)
      assert Enum.any?(found, &(&1.code == :invalid_class and &1.criterion == "CC6.1"))
      assert Enum.any?(found, &(&1.code == :invalid_frequency and &1.criterion == "CC6.2"))
    end

    test "a producer that does not exist", %{tmp_dir: dir} do
      overrides = %{
        "CC4.1" => %{
          "class" => "HOST-APP",
          "evidence_producer" => "module:AshEnterprise.NoSuchProducer"
        }
      }

      path = write!(dir, %{"criteria" => complete_rows(overrides)})

      assert Enum.any?(
               problems(path),
               &(&1.code == :unresolvable_producer and &1.criterion == "CC4.1")
             )
    end

    test "a platform row whose test does not exist is unwired", %{tmp_dir: dir} do
      overrides = %{
        "CC6.1" => %{
          "class" => "PLATFORM-ENFORCED",
          "test_ref" => "file:test/ash_enterprise/no_such_test.exs"
        }
      }

      path = write!(dir, %{"criteria" => complete_rows(overrides)})

      assert Enum.any?(
               problems(path),
               &(&1.code == :unwired_platform_row and &1.criterion == "CC6.1")
             )
    end

    test "a recurring organizational row with no process", %{tmp_dir: dir} do
      overrides = %{"CC1.1" => %{"operating_process" => nil}}
      path = write!(dir, %{"criteria" => complete_rows(overrides)})

      assert Enum.any?(problems(path), &(&1.code == :no_process and &1.criterion == "CC1.1"))
    end

    test "a vendor row with no complementary controls", %{tmp_dir: dir} do
      path = write!(dir, %{"criteria" => complete_rows(%{"CC6.4" => %{"class" => "VENDOR"}})})

      assert Enum.any?(
               problems(path),
               &(&1.code == :no_complementary_controls and &1.criterion == "CC6.4")
             )
    end

    test "a row for a criterion that is not in the catalogue", %{tmp_dir: dir} do
      path = write!(dir, %{"criteria" => [complete_row("CC99.9") | complete_rows()]})

      assert Enum.any?(
               problems(path),
               &(&1.code == :unknown_criterion and &1.criterion == "CC99.9")
             )
    end

    test "a row that is not an object", %{tmp_dir: dir} do
      path = write!(dir, %{"criteria" => ["CC6.1" | complete_rows()]})

      assert :malformed_row in codes(problems(path))
    end
  end
end
