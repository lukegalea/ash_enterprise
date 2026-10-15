defmodule AshEnterprise.Integration.Nango.Info do
  @moduledoc "Introspection over the `nango` DSL section."

  alias AshEnterprise.Integration.Nango.Operation

  @doc "The Nango integration (provider config key) the resource's operations run against."
  def integration(resource), do: Spark.Dsl.Extension.get_opt(resource, [:nango], :integration)

  @doc "The error-classification profile: `:http`, `:google` or `:slack`."
  def errors(resource), do: Spark.Dsl.Extension.get_opt(resource, [:nango], :errors, :http)

  @doc "Every declared operation."
  @spec operations(Spark.Dsl.t() | module()) :: [Operation.t()]
  def operations(resource), do: Spark.Dsl.Extension.get_entities(resource, [:nango])

  @doc "One declared operation by name, or nil."
  @spec operation(Spark.Dsl.t() | module(), atom()) :: Operation.t() | nil
  def operation(resource, name), do: Enum.find(operations(resource), &(&1.name == name))
end
