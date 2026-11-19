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

  # Every query is generated; the sample `say_hello` field the generator leaves here
  # was removed before the contract was pinned, because a field in the pin is a field
  # callers may rely on.
  query do
  end

  mutation do
    # Custom Absinthe mutations can be placed here
  end
end
