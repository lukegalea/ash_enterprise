defmodule AshEnterprise.Integration.Nango.Param do
  @moduledoc """
  One input to a declared provider operation: becomes one argument on the
  generated action, and one query parameter, path segment or body field on the
  proxied request.

  `name` is the Ash argument (snake_case); `as` is the provider's own name for
  it (`"pageToken"`), defaulting to `name`.
  """

  defstruct [
    :name,
    :type,
    :as,
    :default,
    :description,
    in: :query,
    allow_nil?: true,
    constraints: [],
    __identifier__: nil,
    __spark_metadata__: nil
  ]

  @type location :: :query | :path | :body

  @type t :: %__MODULE__{
          name: atom(),
          type: Ash.Type.t(),
          as: String.t() | nil,
          in: location(),
          allow_nil?: boolean(),
          default: term(),
          constraints: keyword(),
          description: String.t() | nil,
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  @doc "The provider's name for this parameter."
  def wire_name(%__MODULE__{as: nil, name: name}), do: Atom.to_string(name)
  def wire_name(%__MODULE__{as: as}), do: as
end
