defmodule AshEnterprise.JudgmentRecordTest do
  @moduledoc """
  The frozen v0 judgment record's validator, against its golden fixtures.

  Every fixture under `test/fixtures/judgment_record/` must validate, and a
  record that violates the RFC's normative rules must fail with a readable
  error — including the admission vocabulary, where "no fact written" is
  `omitted`, never `unknown` (RFC §7.2, Q11).
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.JudgmentRecord

  @fixtures_dir Path.expand(Path.join(["..", "fixtures", "judgment_record"]), __DIR__)

  defp fixture(name) do
    @fixtures_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp fixture_names do
    @fixtures_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
  end

  # Deep-merges `overrides` over the decoded fixture so a test can break one
  # rule at a time while keeping a structurally complete record.
  defp deep_merge(base, overrides) do
    Map.merge(base, overrides, fn
      _key, base_value, override_value ->
        if is_map(base_value) and is_map(override_value) do
          deep_merge(base_value, override_value)
        else
          override_value
        end
    end)
  end

  describe "golden fixtures" do
    test "every fixture validates against the frozen v0 schema" do
      names = fixture_names()

      assert length(names) >= 4, "expected the golden fixture set to be present"

      for name <- names do
        record = fixture(name)

        assert JudgmentRecord.validate(record) == :ok,
               "#{name} must validate — got: #{inspect(JudgmentRecord.validate(record))}"
      end
    end

    test "the envelope's input_digest mirrors judgment.input.input_hash (§5.2)" do
      for name <- fixture_names() do
        record = fixture(name)

        assert record["envelope"]["input_digest"] == record["judgment"]["input"]["input_hash"],
               "#{name}: input_digest must equal input_hash under both names"
      end
    end

    test "instrument zone equals the data zone (ADR 0042, via §5.3)" do
      for name <- fixture_names() do
        record = fixture(name)

        assert record["judgment"]["instrument"]["zone_id"] ==
                 record["judgment"]["input"]["zone_id"],
               "#{name}: a zone mismatch is a disclosure, not an instrument call"
      end
    end
  end

  describe "malformed records" do
    test "an admission result of 'unknown' fails — the value is 'omitted' (§7.2, Q11)" do
      assert {:error, message} = JudgmentRecord.validate_admission_result("unknown")

      assert message =~ "admitted",
             "the error should name the accepted vocabulary, got: #{message}"

      assert JudgmentRecord.validate_admission_result("omitted") == :ok
      assert JudgmentRecord.validate_admission_result("review") == :ok
      assert JudgmentRecord.validate_admission_result("admitted") == :ok
    end

    test "a float probability in the distribution fails the decimal-string rule (§4.3)" do
      record =
        fixture("observation-noul-live.json")
        |> deep_merge(%{
          "judgment" => %{"answer" => %{"distribution" => %{"true" => 0.9412}}}
        })

      assert {:error, message} = JudgmentRecord.validate(record)
      assert message =~ "distribution"
    end

    test "an observation without a data class is rejected (§5.7 rule 2)" do
      record =
        fixture("observation-choice-live.json")
        |> deep_merge(%{"judgment" => %{"input" => %{"data_class" => nil}}})

      assert {:error, message} = JudgmentRecord.validate(record)
      assert message =~ "data_class"
    end

    test "a generative observation without a wire schema hash is rejected (§5.3)" do
      record =
        fixture("observation-extraction-generative.json")
        |> deep_merge(%{
          "judgment" => %{"instrument" => %{"wire_schema_hash" => nil}}
        })

      assert {:error, message} = JudgmentRecord.validate(record)
      assert message =~ "wire_schema_hash"
    end

    test "a shadow observation without shadow_of is rejected (§5.6)" do
      record =
        fixture("observation-evidence-shadow.json")
        |> deep_merge(%{"judgment" => %{"call" => %{"shadow_of" => nil}}})

      assert {:error, message} = JudgmentRecord.validate(record)
      assert message =~ "shadow_of"
    end

    test "a digest truncated to the semantic-manifest's 128 bits fails (§4.2, Q4)" do
      record =
        fixture("observation-noul-live.json")
        |> deep_merge(%{
          "judgment" => %{
            "question" => %{"question_hash" => "sha256:0227af26996bd9b7"}
          }
        })

      assert {:error, message} = JudgmentRecord.validate(record)
      assert message =~ "question_hash"
    end
  end

  describe "question registry definitions (§3)" do
    test "the question_hash input object validates (§3.2)" do
      input = %{
        "answer_type" => "AshAi.Evaluate.Choice",
        "criteria" => %{"soon" => "synthetic criteria text"},
        "instructions" => "synthetic instructions",
        "options" => ["routine", "soon", "urgent"],
        "state_contract" => "sha256:" <> String.duplicate("a", 64),
        "version" => 3
      }

      assert JudgmentRecord.validate_question_hash_input(input) == :ok

      # family is not in the hash (Q3) and lineage is not in the hash (ADR 0039):
      # the hashed object is closed — an extra key would change the digest.
      assert {:error, message} =
               JudgmentRecord.validate_question_hash_input(Map.put(input, "family", "x.y"))

      assert message =~ "family"
    end

    test "the wire question object validates (§3.3)" do
      assert JudgmentRecord.validate_wire_question(%{
               "type" => "choice",
               "instructions" => "synthetic",
               "criteria" => %{}
             }) == :ok

      assert {:error, _} = JudgmentRecord.validate_wire_question(%{"instructions" => "x"})
    end
  end

  test "the schema is the frozen draft-2020-12 document in priv/" do
    assert JudgmentRecord.schema_path() =~ "priv/judgment_record/schema.json"
    assert JudgmentRecord.schema()["$schema"] == "https://json-schema.org/draft/2020-12/schema"
  end
end
