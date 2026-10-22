defmodule AshEnterprise.Licences.RungsTest do
  @moduledoc """
  S1-63: the licence questions, declared, and the rung split (AC-2).

  The nine questions on `AshEnterprise.Licences.Dependency` are the bytes
  Luke Galea confirmed on 2026-10-21 (record 73da9055): their registry
  hashes equal the confirmed hashes and the lock's. Over the hex.pm licence
  corpus (public metadata, `test/fixtures/licences/`), every subject that
  declares a single classified SPDX id is answered by the declaration rung,
  identically to the research run's `declaration-rung.csv`, with no model
  call; the triaged anomalies stay excluded with their reasons; and only a
  subject without such an id reaches a model.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Licences
  alias AshEnterprise.Licences.{Corpus, Dependency, EvalSet, Rungs}
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.CalibrationInput
  alias AshEnterprise.SystemOne.Judgment
  alias AshEnterprise.SystemOne.TestSupport.FakeReqLLM
  alias AshJudgments.Registry.Info
  alias NimbleCSV.RFC4180, as: CSV

  @fixtures Path.expand("../../fixtures/licences", __DIR__)
  @lock_file Path.expand("../../../priv/judgments/lock.json", __DIR__)

  # declaration-rung.csv is keyed by policy clause; the confirmed questions
  # map onto its columns one to one (lic-7 is the negation of its column).
  @clause_columns [
    package_licence_is_permissive: "lic-1_permissive_allowed",
    package_licence_is_strong_copyleft: "lic-2_strong_copyleft",
    package_licence_is_weak_copyleft: "lic-3_weak_copyleft_review",
    package_licence_is_network_copyleft: "lic-4_network_copyleft",
    package_licence_requires_attribution: "lic-5_attribution_listed",
    package_requires_notice_file: "lic-6_notice_check",
    package_licence_declaration_invalid: "lic-7_valid_spdx_declared",
    package_is_public_domain_dedication: "lic-8_public_domain_equivalent",
    package_licence_has_use_restrictions: "lic-9_use_restricted"
  ]

  setup do
    Correlation.start_new()
    System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")
    FakeReqLLM.reset_calls()

    on_exit(fn ->
      System.delete_env("S1_OLLAYA_GPU_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
    end)

    %{tenant: Ash.UUID.generate(), actor: SystemActor.migration()}
  end

  describe "the declared questions" do
    test "are the confirmed entries of record 73da9055, verbatim, and the lock holds them" do
      [record] = @fixtures |> Path.join("confirmed.json") |> File.read!() |> Jason.decode!()
      assert record["id"] == "73da9055-7d92-4b2d-9930-acda885f4d48"
      assert record["status"] == "confirmed"

      confirmed = Map.new(record["proposals"], &{&1["name"], &1})
      declared = Info.questions(Dependency)
      lock = @lock_file |> File.read!() |> Jason.decode!()

      assert Enum.map(declared, & &1.name) == Rungs.questions()
      assert MapSet.new(declared, &Atom.to_string(&1.name)) == MapSet.new(Map.keys(confirmed))

      for question <- declared do
        entry = Map.fetch!(confirmed, Atom.to_string(question.name))
        assert question.question_hash == entry["question_hash"]
        assert question.version == 1
        assert question.family == :third_party_licence
        assert question.profile == :winnow_gpu
        assert lock[question.question_id] == %{"hash" => entry["question_hash"], "version" => 1}
      end
    end
  end

  describe "AC-2: the declaration-first rung" do
    test "a declared SPDX id is answered without a model call; only a subject without one reaches the model",
         %{tenant: tenant, actor: actor} do
      %{subjects: attrs, excluded: excluded} =
        Corpus.subjects(
          Path.join(@fixtures, "corpus.csv"),
          Path.join(@fixtures, "excluded-anomalies.csv")
        )

      # The corpus: 652 packages. The 94 triaged anomalies stay out with
      # their reasons, and so do the two with no stable release (no release,
      # no subject).
      assert length(attrs) + length(excluded) == 652
      assert Enum.all?(excluded, &(&1.reason != "" and &1.kinds != ""))
      assert Enum.count(excluded, &(&1.kinds != "no_version")) == 94

      assert excluded |> Enum.filter(&(&1.kinds == "no_version")) |> Enum.map(& &1.package) ==
               ["multigraph", "opentelemetry_liveview"]

      subjects =
        Enum.map(attrs, &Licences.register_dependency!(&1, actor: actor, tenant: tenant))

      assert length(subjects) == 556

      routes = Map.new(subjects, &{&1.package, {&1, Rungs.route(&1)}})

      # Every declared subject is on the declaration rung; none is sent on.
      assert Enum.frequencies_by(Map.values(routes), fn {_s, r} -> r.rung end) == %{
               declaration: 556
             }

      assert Enum.all?(Map.values(routes), fn {_s, r} -> r.to_model == [] end)

      # The rung's answers are the research run's, cell for cell.
      expected = expected_answers()
      # The research run answered 558 by name; the two unversioned ones are
      # the difference, and their declarations route the same way.
      assert map_size(expected) == 558

      for name <- ["multigraph", "opentelemetry_liveview"] do
        assert Rungs.route(%{declared_licences: [expected[name].spdx_id]}).rung == :declaration
      end

      for {package, {_subject, route}} <- routes do
        want = Map.fetch!(expected, package)
        assert route.spdx_id == want.spdx_id

        for {question, value} <- want.answers do
          case value do
            :needs_package_contents ->
              assert route.pending[question] == :needs_package_contents

            value ->
              assert route.answers[question] == value,
                     "#{package} #{question}: #{inspect(route.answers[question])} != #{value}"
          end
        end
      end

      # Asking a model about a declared subject is refused before any call.
      for {subject, _route} <- Enum.take(Map.values(routes), 25), question <- Rungs.questions() do
        assert {:error, {:answered_without_model, ^question}} =
                 Rungs.judge(subject, question,
                   actor: actor,
                   tenant: tenant,
                   judgments: %{req_llm: FakeReqLLM}
                 )
      end

      assert FakeReqLLM.calls() == 0

      # A release with no declaration goes to the model for the eight
      # licence questions; the declaration itself answers lic-7.
      undeclared =
        Licences.register_dependency!(
          %{
            package: "synthetic_undeclared",
            version: "0.1.0",
            declared_licences: [],
            licence_text: "Permission is hereby granted, free of charge, to any person...",
            package_files: ["LICENSE", "mix.exs"]
          },
          actor: actor,
          tenant: tenant
        )

      route = Rungs.route(undeclared)
      assert route.rung == :model
      assert route.answers == %{package_licence_declaration_invalid: true}
      assert length(route.to_model) == 8
      refute :package_licence_declaration_invalid in route.to_model

      # An unclassified declaration also goes to the model, and its lic-7
      # answer waits for a person.
      unclassified = Rungs.route(%{declared_licences: ["Apache 2.0"]})
      assert unclassified.rung == :model
      assert unclassified.pending == %{package_licence_declaration_invalid: :needs_person}

      assert {:ok, %{probability: _}} =
               Rungs.judge(undeclared, :package_licence_is_permissive,
                 actor: actor,
                 tenant: tenant,
                 judgments: %{req_llm: FakeReqLLM}
               )

      assert FakeReqLLM.calls() == 1
      assert_received {:judge_call, _spec, state, _questions}
      # The model reads the licence text and file names, never the declaration.
      assert state == %{"input" => Rungs.model_input(undeclared)}

      [observation] = Ash.read!(Judgment, tenant: tenant, authorize?: false)
      assert observation.subject_id == undeclared.id
      assert observation.family == "third_party_licence"
      assert observation.state_ref == %{"purpose" => "live"}
    end
  end

  describe "AC-1 machinery: a calibration pass" do
    test "asks the model about declared subjects on purpose and scores it against the declaration",
         %{tenant: tenant, actor: actor} do
      mit =
        Licences.register_dependency!(
          %{package: "synthetic_mit", version: "1.0.0", declared_licences: ["MIT"]},
          actor: actor,
          tenant: tenant
        )

      mpl =
        Licences.register_dependency!(
          %{package: "synthetic_mpl", version: "1.0.0", declared_licences: ["MPL-2.0"]},
          actor: actor,
          tenant: tenant
        )

      for subject <- [mit, mpl] do
        assert {:ok, _} =
                 Rungs.judge(subject, :package_licence_is_weak_copyleft,
                   actor: actor,
                   tenant: tenant,
                   calibration?: true,
                   judgments: %{req_llm: FakeReqLLM}
                 )
      end

      assert FakeReqLLM.calls() == 2

      doc = EvalSet.build(actor: actor, tenant: tenant)
      assert doc["family"] == "third_party_licence"

      assert doc["pairs"] |> Enum.map(&{&1["package"], &1["gold"], &1["p"]}) |> Enum.sort() ==
               [{"synthetic_mit", false, 0.9}, {"synthetic_mpl", true, 0.9}]

      bytes = Jason.encode!(doc)
      input = CalibrationInput.input(Jason.decode!(bytes), bytes)
      assert input.answer_kind == :noul
      assert input.n_per_class == %{"false" => 1, "true" => 1}
      assert input.eval_set_hash =~ ~r/^sha256:[0-9a-f]{64}$/

      attrs = CalibrationInput.run_attrs("third_party_licence", input)
      assert attrs.n == 2
      assert is_binary(attrs.ece) and is_binary(attrs.brier)
    end
  end

  defp expected_answers do
    [header | rows] =
      @fixtures
      |> Path.join("declaration-rung.csv")
      |> File.read!()
      |> CSV.parse_string(skip_headers: false)

    rows
    |> Enum.map(fn row -> header |> Enum.zip(row) |> Map.new() end)
    |> Map.new(fn row ->
      answers =
        Map.new(@clause_columns, fn {question, column} ->
          {question, cell(question, row[column])}
        end)

      {row["package"], %{spdx_id: row["spdx_id"], answers: answers}}
    end)
  end

  defp cell(:package_licence_declaration_invalid, "true"), do: false
  defp cell(:package_requires_notice_file, "not_applicable"), do: false
  defp cell(:package_requires_notice_file, "needs_package_contents"), do: :needs_package_contents
  defp cell(_question, "true"), do: true
  defp cell(_question, "false"), do: false
end
