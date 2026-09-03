defmodule AshEnterprise.AI.SurfaceSpec do
  @moduledoc """
  What the model composed for an ad-hoc table request.

  A plain typed struct with no behaviour, mirroring `AshEnterprise.AI.Intent`.
  The composed surface spec is genuinely free-form -- its vocabulary is the
  `ash_a2ui` dynamic allowlist, not a fixed set of keys -- so it arrives as
  JSON **text** in `spec` rather than as nested maps. That is not a dodge:
  OpenAI's Responses API rejects any structured-output schema containing an
  open object (every object must carry `additionalProperties: false`), so a
  `:map` return cannot be given a valid schema at all. A closed
  string-carrying struct can, and the server still validates the decoded JSON
  against the same allowlist the prompt was generated from before anything is
  rendered.

  The struct also **is** the schema: `ash_ai` derives the JSON schema the
  model is constrained to from these field definitions, so there is no
  separate schema to drift.
  """

  use Ash.TypedStruct

  @type t :: %__MODULE__{
          spec: String.t()
        }

  typed_struct do
    field :spec, :string,
      allow_nil?: false,
      constraints: [min_length: 2],
      description:
        "The JSON text of one table specification matching the schema given in the prompt. " <>
          "Return the specification itself as a JSON string, not a nested object."
  end
end
