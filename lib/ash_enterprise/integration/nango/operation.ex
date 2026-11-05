defmodule AshEnterprise.Integration.Nango.Operation do
  @moduledoc """
  One declared provider operation: an HTTP method and a provider path, proxied
  through Nango. Becomes one generic action of the same name.

  `path` is relative to the provider base URL Nango holds for the integration
  (e.g. `https://www.googleapis.com` for Google Calendar) and may carry
  `{param}` placeholders, each filled from a `param ..., in: :path`.
  """

  defstruct [
    :name,
    :method,
    :path,
    :description,
    numbers: :float,
    params: [],
    __identifier__: nil,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          method: :get | :post,
          path: String.t(),
          description: String.t() | nil,
          numbers: :float | :decimal,
          params: [AshEnterprise.Integration.Nango.Param.t()],
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  @placeholder ~r/\{([a-z][a-z0-9_]*)\}/

  @doc "The `{placeholder}` names in the path, as strings, in order."
  def placeholders(%__MODULE__{path: path}) do
    @placeholder
    |> Regex.scan(path, capture: :all_but_first)
    |> List.flatten()
  end

  @doc false
  def placeholder_regex, do: @placeholder
end
