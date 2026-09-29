defmodule AshEnterpriseWeb.Plugs.CheckCodegenStatus do
  @moduledoc """
  `AshPhoenix.Plug.CheckCodegenStatus`, skipped when this application is hosted
  in an owned schema (`ASH_SCHEMA` set, see `config/dev.exs`).

  The resource snapshots record each foreign key's destination schema as
  `AshEnterprise.Repo.default_prefix/0` returned on the machine that generated
  them, which is `"public"`. With `ASH_SCHEMA=canonical` the same callback
  returns `"canonical"`, so the dev-time check sees every such key as changed
  and answers every request with `PendingCodegen`. That is not drift: the
  migrations resolve those keys with `prefix: prefix()` and replay cleanly into
  `canonical` (`scripts/schema-portable-migrations.sh`). Real drift is caught
  where the snapshots were written for, by `mix ash.codegen --check` in CI.

  Read at request time rather than compile time, so a build compiled without
  `ASH_SCHEMA` and run with it behaves the same as one compiled with it.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: AshPhoenix.Plug.CheckCodegenStatus.init(opts)

  @impl true
  def call(conn, opts) do
    if System.get_env("ASH_SCHEMA") in [nil, ""] do
      AshPhoenix.Plug.CheckCodegenStatus.call(conn, opts)
    else
      conn
    end
  end
end
