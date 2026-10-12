defmodule AshEnterprise.Integration.SourceRecord do
  @moduledoc """
  One fetched provider object, as an adapter hands it to
  `AshEnterprise.Integration.Landing.land/2`. Field-for-field what
  `AshEnterprise.Ingestion.SourceObject.land` accepts, with the stream lifted
  out of `source_metadata` so the lander cannot lose it.
  """

  @enforce_keys [:external_system, :external_id, :stream, :raw_payload]
  defstruct [
    :external_system,
    :external_id,
    :stream,
    :raw_payload,
    :cursor,
    :fetched_at,
    source_metadata: %{}
  ]

  @type t :: %__MODULE__{
          external_system: String.t(),
          external_id: String.t(),
          stream: String.t(),
          raw_payload: map(),
          cursor: map() | nil,
          fetched_at: DateTime.t() | nil,
          source_metadata: map()
        }
end
