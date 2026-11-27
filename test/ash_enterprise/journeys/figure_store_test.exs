defmodule AshEnterprise.Journeys.FigureStoreTest do
  @moduledoc """
  The audit copy of approved journey figures (`AshEnterprise.Journeys.FigureStore`), from
  the offboarding journey's approved run in `priv/journeys/`.
  """

  use AshEnterprise.DataCase, async: true

  @moduletag :tmp_dir
  @moduletag evidence: true

  require Ash.Query

  alias AshEnterprise.Journeys.FigureStore
  alias AshEvidence.{DocumentVersion, EvidenceEvaluation, Packet, ParseRun}
  alias AshJourneys.Lock

  @id "revoke_a_leavers_access"

  defp root, do: Application.app_dir(:ash_enterprise)

  defp entry(locale) do
    {:ok, lock} = Lock.read(root())
    lock.journeys[@id][locale]
  end

  defp figures, do: DocumentVersion |> Ash.Query.filter(kind == "journey-figure") |> Ash.read!()

  defp runs(version_id),
    do: ParseRun |> Ash.Query.filter(document_version_id == ^version_id) |> Ash.read!()

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp meta(overrides \\ %{}) do
    Map.merge(
      %{
        journey: @id,
        locale: "en",
        run: entry("en").run,
        step: "deactivate",
        figure: "confirm",
        highlight: nil,
        traces: []
      },
      overrides
    )
  end

  defp approved_bytes(key) do
    figure = entry("en").figures[key]
    File.read!(Path.join(Lock.approved_dir(root(), "en", @id), figure.file))
  end

  describe "archive/3" do
    test "stores each approved figure as a version whose bytes hash to the lock" do
      entry = entry("en")
      assert {:ok, refs} = FigureStore.archive(@id, "en")

      assert Enum.sort(refs) ==
               entry.figures |> Map.values() |> Enum.map(& &1.file_sha256) |> Enum.sort()

      for {key, figure} <- entry.figures do
        assert {:ok, bytes} = FigureStore.fetch(figure.file_sha256)
        assert sha256(bytes) == figure.file_sha256, key
      end

      versions = figures()
      assert length(versions) == map_size(entry.figures)
      assert Enum.all?(versions, &(&1.kind == "journey-figure" and is_nil(&1.tenant)))
    end

    test "records one closed playwright run per execution, and the highlight as a :region atom" do
      entry = entry("en")
      {:ok, _refs} = FigureStore.archive(@id, "en")

      for {key, figure} <- entry.figures do
        [version] = Enum.filter(figures(), &(&1.sha256 == figure.file_sha256))
        assert [run] = runs(version.id)

        assert %{instrument: "playwright", status: :ok} = run

        assert %{
                 "run" => run_id,
                 "commit" => commit,
                 "journey" => @id,
                 "locale" => "en",
                 "key" => ^key,
                 "declaration_hash" => hash,
                 "raster_sha256" => raster,
                 "browser" => %{"name" => "chromium"},
                 "trace_sha256" => []
               } = run.config

        assert {run_id, commit, hash, raster} ==
                 {entry.run, entry.commit, entry.hash, figure.raster_sha256}

        atoms = AshEvidence.Domain.atoms_for_run!(run.id)

        case key do
          "find_the_person.people" ->
            assert [atom] = atoms
            assert %{kind: :region, page: 1} = atom
            assert %{unit: :px, page_w: 1280.0, page_h: 800.0, bbox: bbox} = atom.geometry
            assert_in_delta bbox.x0, 34.0 / 1280, 1.0e-9
            assert_in_delta bbox.y0, 414.5 / 800, 1.0e-9
            assert_in_delta bbox.x1, (34.0 + 1212.0) / 1280, 1.0e-9
            assert_in_delta bbox.y1, (414.5 + 47.5) / 800, 1.0e-9

            assert run.config["highlight"] == %{
                     "x" => 34.0,
                     "y" => 414.5,
                     "width" => 1212.0,
                     "height" => 47.5
                   }

          _no_highlight ->
            assert atoms == []
            assert run.config["highlight"] == nil
        end
      end
    end

    test "storing one execution again adds nothing; another locale's execution is its own run" do
      {:ok, refs} = FigureStore.archive(@id, "en")
      before = for version <- figures(), run <- runs(version.id), do: run.id

      assert {:ok, ^refs} = FigureStore.archive(@id, "en")

      assert Enum.sort(for version <- figures(), run <- runs(version.id), do: run.id) ==
               Enum.sort(before)

      assert {:ok, fr_refs} = FigureStore.archive(@id, "fr")
      assert length(fr_refs) == map_size(entry("fr").figures)

      for ref <- fr_refs do
        [version] = Enum.filter(figures(), &(&1.sha256 == ref))
        assert Enum.any?(runs(version.id), &(&1.config["locale"] == "fr"))
      end
    end

    test "records a trace file's hash and never its bytes", %{tmp_dir: dir} do
      trace = Path.join(dir, "trace.zip")
      File.write!(trace, "PK\x03\x04 not really a trace")

      {:ok, refs} = FigureStore.archive(@id, "en", traces: [trace])

      for ref <- refs do
        [version] = Enum.filter(figures(), &(&1.sha256 == ref))
        assert [%{config: %{"trace_sha256" => [digest]}}] = runs(version.id)
        assert digest == sha256(File.read!(trace))
      end

      assert DocumentVersion
             |> Ash.Query.filter(sha256 == ^sha256(File.read!(trace)))
             |> Ash.read!() == []
    end

    test "refuses a stale approved run and writes nothing", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "priv"))
      File.cp_r!(Path.join(root(), "priv/journeys"), Path.join(dir, "priv/journeys"))
      lock_path = Lock.path(dir)
      lock = lock_path |> File.read!() |> Jason.decode!()

      File.write!(
        lock_path,
        Jason.encode!(put_in(lock, ["journeys", @id, "en", "hash"], String.duplicate("0", 64)))
      )

      assert {:error, {:not_approved, reason}} = FigureStore.archive(@id, "en", root: dir)
      assert reason =~ "is stale"
      assert figures() == []
    end

    test "refuses a journey no module declares, and a locale with no approved run", %{
      tmp_dir: dir
    } do
      assert {:error, {:not_approved, "no configured module declares journey nope"}} =
               FigureStore.archive("nope", "en")

      assert {:error, {:not_approved, reason}} = FigureStore.archive(@id, "en", root: dir)
      assert reason =~ "is unapproved"
      assert figures() == []
    end
  end

  describe "put/2" do
    test "stores the approved bytes and returns their file_sha256" do
      bytes = approved_bytes("deactivate.confirm")
      assert {:ok, ref} = FigureStore.put(bytes, meta())
      assert ref == entry("en").figures["deactivate.confirm"].file_sha256
      assert FigureStore.fetch(ref) == {:ok, bytes}
    end

    test "refuses bytes that do not hash to the lock's file_sha256, and writes nothing" do
      bytes = approved_bytes("deactivate.confirm") <> <<0>>

      assert {:error, {:not_approved, reason}} = FigureStore.put(bytes, meta())

      assert reason =~
               "but the lock approved #{entry("en").figures["deactivate.confirm"].file_sha256}"

      # The bytes of another approved figure are not this one either.
      assert {:error, {:not_approved, _}} =
               FigureStore.put(approved_bytes("deactivate.deactivated"), meta())

      assert figures() == []
      assert FigureStore.fetch(sha256(bytes)) == {:error, :not_found}
    end

    test "refuses another run, a figure the run did not shoot, and an unapproved locale" do
      bytes = approved_bytes("deactivate.confirm")

      for {overrides, expected} <- [
            {%{run: "ci-1"}, "is not the approved run"},
            {%{figure: "nope"}, "has no figure deactivate.nope"},
            {%{locale: "de"}, "no approved run of #{@id} in de"},
            {%{journey: "nope"}, "no approved run of nope in en"},
            {%{traces: ["not a digest"]}, "trace digests must be"}
          ] do
        assert {:error, {:not_approved, reason}} = FigureStore.put(bytes, meta(overrides))
        assert reason =~ expected
      end

      assert figures() == []
    end
  end

  test "uses no packet, evidence evaluation or assertion" do
    {:ok, _refs} = FigureStore.archive(@id, "en")

    assert Ash.count!(Packet) == 0
    assert Ash.count!(EvidenceEvaluation) == 0

    source = File.read!("lib/ash_enterprise/journeys/figure_store.ex")
    refute source =~ ~r/Packet\b|EvidenceEvaluation|Assertion|assemble_packet|start_evaluation/
  end
end
