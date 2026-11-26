defmodule AshEnterprise.Guides.Schema do
  @moduledoc """
  Checks a list of A2UI 1.0 agent-to-renderer messages against the vendored
  specification (`agent_to_renderer_list.json`) with the basic catalog, before a
  guide is served (`AshEnterprise.Guides`). A message the browser cannot apply
  renders as nothing, so it is refused here, where it can be named.

  The schema is built when this module compiles, from the files
  `AshEnterprise.Guides.Schema.Resolver` serves.
  """

  alias AshEnterprise.Guides.Schema.Resolver

  # Law 16: the schemas are read at compile time, so a new ash_a2ui copy recompiles this.
  for file <- Resolver.files(), do: @external_resource(file)

  @root JSV.build!(%{"$ref" => Resolver.base() <> "agent_to_renderer_list.json"},
          resolver: [Resolver, JSV.Resolver.Embedded],
          formats: true
        )

  @doc "`:ok`, or `{:error, reason}` naming where `messages` break the schema."
  @spec validate([map()]) :: :ok | {:error, String.t()}
  def validate(messages) when is_list(messages) do
    case JSV.validate(messages, @root, cast: false) do
      {:ok, _messages} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end
end
