defmodule AshEnterpriseWeb.GraphqlSchema do
  @moduledoc """
  The Absinthe schema, generated from the domains that opt in.

  Nothing here is hand-written: types, filter inputs, sort inputs and pagination
  are all derived from resources declaring a `graphql` type. The comment below
  records the compile-time failure you get from an empty domain list.
  """
  use Absinthe.Schema

  # Every domain that should appear in the GraphQL schema is listed here.
  # AshGraphql cannot be given an empty list -- it fails at compile time with
  # `:erlang.element(1, nil)` -- so a new project must wire up its first domain
  # before this module will build.
  use AshGraphql,
    domains: [AshEnterprise.Accounts]

  import_types Absinthe.Plug.Types

  query do
    # Custom Absinthe queries can be placed here
    @desc """
    Hello! This is a sample query to verify that AshGraphql has been set up correctly.
    Remove me once you have a query of your own!
    """
    field :say_hello, :string do
      resolve fn _, _, _ ->
        {:ok, "Hello from AshGraphql!"}
      end
    end
  end

  mutation do
    # Custom Absinthe mutations can be placed here
  end

  subscription do
    # Custom Absinthe subscriptions can be placed here
  end
end
