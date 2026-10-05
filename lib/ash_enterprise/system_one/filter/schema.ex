defmodule AshEnterprise.SystemOne.Filter.Schema do
  @moduledoc """
  The wire JSON Schema for NL-to-filter translation proposals (S1-65;
  S1-56 §3.2, S1-57 §5b): the Basic CQL2-JSON profile, with property names
  RESTRICTED to the declared queryables (`Filter.Queryables`).

  This is ADR 0046's mechanism with a derived contract: where the question
  proposal's schema is a static file, this schema is DERIVED at call time —
  the property-name enum *is* the declared vocabulary, so a declaration
  change re-derives the contract without any file drift. The schema rides
  the wire as the structured-output contract (the transport constrains
  generation with it) and is validated post-decode with JSV, exactly like
  the frozen judgment-record validator.

  Division of labour (the question-proposal pattern — decode where the
  wire can, validate always):

  - **The schema** enforces shape: the operator enum (Basic CQL2 plus the
    `in` member of the Advanced Comparison class — the one the Basic slice
    admits), the recursive `args` tree, and property operands restricted to
    the declared queryables. A property outside the vocabulary cannot even
    decode.
  - **The typed pass** (`Filter.Document.decode/2`) enforces what JSON
    Schema cannot express across positions: property↔literal type
    agreement, enum membership, ordering operators only on numeric
    properties, and per-operator arity and operand shapes.

  A schema-invalid or undecodable answer is a readable refusal with the raw
  output retained on the proposal — never a best-effort parse.
  """

  @operators ["=", "<>", "<", "<=", ">", ">=", "in", "and", "or", "isNull"]

  @max_args 20

  @doc "The operator words the Basic slice admits (CQL2 spellings)."
  @spec operators() :: [String.t()]
  def operators, do: @operators

  @doc """
  The derived wire schema (draft 2020-12) as a string-keyed map, restricted
  to the queryables currently declared. Built at call time on purpose: the
  vocabulary is derived from declarations (ADR 0046), not frozen in a file.
  """
  @spec schema() :: map()
  def schema do
    names = Enum.map(AshEnterprise.SystemOne.Filter.Queryables.all(), & &1.name)

    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "title" => "System One filter proposal — Basic CQL2 document",
      "description" =>
        "The wire contract for NL-to-filter translation (S1-65). Property names are RESTRICTED " <>
          "to the declared queryables of the facts surface. A schema-valid document is a " <>
          "well-formed PROPOSAL, never an executed one: a person approves it before it runs.",
      "type" => "object",
      "required" => ["op", "args"],
      "additionalProperties" => false,
      "properties" => %{
        "_comment" => %{
          "type" => "string",
          "description" =>
            "Documentation key (SPDX/REUSE annotations on fixtures). Ignored by decode."
        },
        "op" => %{"enum" => @operators},
        "args" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_args,
          "items" => %{"$ref" => "#/$defs/node"}
        }
      },
      "$defs" => %{
        "node" => %{
          "oneOf" => [
            %{"$ref" => "#"},
            %{"$ref" => "#/$defs/property"},
            %{"$ref" => "#/$defs/literal"},
            %{"$ref" => "#/$defs/literal_list"}
          ]
        },
        "property" => %{
          "type" => "object",
          "required" => ["property"],
          "additionalProperties" => false,
          "properties" => %{
            "property" => %{
              "type" => "string",
              "enum" => names,
              "description" =>
                "A declared queryable of the facts surface. Anything else is refused, never silently dropped."
            }
          }
        },
        "literal" => %{
          "type" => ["string", "number", "boolean"],
          "description" =>
            "A scalar literal. Typed agreement with the property is checked post-decode."
        },
        "literal_list" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_args,
          "items" => %{"type" => ["string", "number", "boolean"]},
          "description" => "The value list of an `in` — non-empty, homogeneous, property-typed."
        }
      }
    }
  end

  @doc """
  Schema-validates decoded model output (a whole Basic-CQL2 document tree).
  Returns `:ok` or a readable refusal.
  """
  @spec validate_document(term()) :: :ok | {:error, String.t()}
  def validate_document(document) do
    root = JSV.build!(schema())

    case JSV.validate(document, root) do
      {:ok, _} -> :ok
      {:error, %JSV.ValidationError{} = error} -> {:error, Exception.message(error)}
    end
  end
end
