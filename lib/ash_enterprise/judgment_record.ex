defmodule AshEnterprise.JudgmentRecord do
  @moduledoc """
  Validates System One judgment records against the frozen v0 JSON Schema.

  The contract is RFC S1-24, `docs/rfc/judgment-record-v0.md` — status
  **"ACCEPTED — v0 FROZEN"**: edits go to a v1 draft, never to v0. This
  module is the executable half of that freeze for the observation envelope
  (§3–§5): the schema is read from `priv/judgment_record/schema.json` at
  compile time and built with JSV, so a malformed schema is a compile error
  and any byte drift from the frozen artefacts is caught by the golden-hash
  test (`test/ash_enterprise/judgment_record_golden_test.exs`).

  The top-level schema validates the observation record: the provenance
  envelope core plus the `judgment` extension — question identity
  (`judgment:v0:<Module>#judgments/<name>`, §3.1), instrument identity by
  digests rather than names (§5.3), decimal-string probabilities (§4.3),
  and the payload-class fields that stay out of `record_hash` (§10). The
  named definitions validate the pieces of §3 a registry implementation
  needs: `$defs/question_hash_input` (§3.2), `$defs/wire_question` (§3.3)
  and `$defs/admission_result` — where "no fact written" is `omitted`,
  never `unknown` (§7.2, Q11).

  All schema constraints are `additionalProperties: true` except the
  question-hash input object, per §11: within major version 0 the record is
  additive and consumers ignore unknown fields.
  """

  @schema_path Path.expand(
                 Path.join(["..", "..", "priv", "judgment_record", "schema.json"]),
                 __DIR__
               )

  # Law 16: the schema is read at compile time, so it must be declared as an
  # external resource — otherwise editing the schema would not recompile this
  # module and the validator would silently disagree with the file on disk.
  @external_resource @schema_path

  @schema_json File.read!(@schema_path)
  @schema Jason.decode!(@schema_json)
  @defs @schema["$defs"]

  # Named roots into $defs, built once at compile time from the same
  # document. The maps are literal because module attributes are evaluated
  # as the compiler reads them, before any function of this module exists.
  @root JSV.build!(@schema)

  @question_hash_input_root JSV.build!(%{
                              "$schema" => "https://json-schema.org/draft/2020-12/schema",
                              "$ref" => "#/$defs/question_hash_input",
                              "$defs" => @defs
                            })
  @wire_question_root JSV.build!(%{
                        "$schema" => "https://json-schema.org/draft/2020-12/schema",
                        "$ref" => "#/$defs/wire_question",
                        "$defs" => @defs
                      })
  @admission_result_root JSV.build!(%{
                           "$schema" => "https://json-schema.org/draft/2020-12/schema",
                           "$ref" => "#/$defs/admission_result",
                           "$defs" => @defs
                         })

  @doc """
  Absolute path of the frozen v0 schema this module validates against.
  """
  @spec schema_path() :: String.t()
  def schema_path, do: @schema_path

  @doc """
  The decoded v0 schema (draft 2020-12) as a string-keyed map.
  """
  @spec schema() :: map()
  def schema, do: @schema

  @doc """
  Validates one observation record (RFC §5: the envelope plus the judgment
  extension).

  Returns `:ok`, or `{:error, message}` with the JSV error formatted for a
  reader: the instance location, the schema location and the reason.
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(record), do: run(@root, record)

  @doc """
  Validates the exact object whose canonical JSON is digested into
  `question_hash` (RFC §3.2).
  """
  @spec validate_question_hash_input(term()) :: :ok | {:error, String.t()}
  def validate_question_hash_input(input), do: run(@question_hash_input_root, input)

  @doc """
  Validates the exact question object sent on the wire, whose canonical JSON
  is digested into `wire_question_hash` (RFC §3.3).
  """
  @spec validate_wire_question(term()) :: :ok | {:error, String.t()}
  def validate_wire_question(question), do: run(@wire_question_root, question)

  @doc """
  Validates the admission result vocabulary (RFC §7.2): `admitted`, `review`
  or `omitted` — never `unknown`, which is an ash_rules outcome, not an
  admission value (Q11).
  """
  @spec validate_admission_result(term()) :: :ok | {:error, String.t()}
  def validate_admission_result(result), do: run(@admission_result_root, result)

  defp run(root, data) do
    case JSV.validate(data, root) do
      {:ok, _validated} -> :ok
      {:error, %JSV.ValidationError{} = error} -> {:error, Exception.message(error)}
    end
  end
end
