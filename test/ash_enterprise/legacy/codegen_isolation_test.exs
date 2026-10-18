defmodule AshEnterprise.Legacy.CodegenIsolationTest do
  @moduledoc """
  Ash must never own the legacy schema.

  This is the hard rule of the strangler demonstration and the thing that makes
  it honest rather than circular: the whole exercise is about migrating a schema
  this application does not control, and the moment `mix ash.codegen` starts
  emitting DDL for `legacy.*` the demo is describing a situation it is no longer
  in. See `priv/legacy/README.md`.

  It is enforced here rather than by convention because the failure is quiet. A
  resource left at the default `migrate? true` produces a snapshot, codegen
  diffs against it, and the next generated migration contains a `create table`
  for a relation that already exists — or worse, for the *view's* own name, at
  which point the view DDL fails against a table Ash just created.
  """

  use ExUnit.Case, async: true

  @legacy_schemas ["legacy", "strangler"]

  defp legacy_resources do
    [AshEnterprise.Legacy.Twins, AshEnterprise.Legacy]
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
  end

  test "there is something to check" do
    # A test that silently covers nothing is worse than no test. The rule below
    # is vacuously true for an empty list.
    assert legacy_resources() != []
  end

  test "every resource reading a legacy relation declares migrate? false" do
    for resource <- legacy_resources() do
      schema = AshPostgres.DataLayer.Info.schema(resource)

      assert schema in @legacy_schemas,
             "#{inspect(resource)} is in a legacy domain but reads schema #{inspect(schema)}"

      refute AshPostgres.DataLayer.Info.migrate?(resource),
             """
             #{inspect(resource)} would be included in `mix ash.codegen`.

             Ash owns the compatibility view, not the tables underneath it, and it
             owns neither at the point where codegen emits `create table`. Declare
             `migrate? false` in its `postgres` block.
             """
    end
  end

  test "no resource snapshot describes a legacy or strangler relation" do
    # `migrate? false` is what stops a snapshot being written, so a snapshot
    # mentioning either schema means the flag came off somewhere. Checking the
    # artefact rather than the flag catches the case where a resource was added
    # correctly, generated once incorrectly, and then fixed — leaving the stale
    # snapshot behind to be diffed against forever.
    snapshots = Path.wildcard("priv/resource_snapshots/**/*.json")

    assert snapshots != [], "no snapshots found -- is the working directory wrong?"

    offenders =
      Enum.filter(snapshots, fn path ->
        case JSON.decode(File.read!(path)) do
          {:ok, %{"schema" => schema}} -> schema in @legacy_schemas
          _ -> false
        end
      end)

    assert offenders == [],
           """
           These snapshots describe a schema this application does not own:

           #{Enum.map_join(offenders, "\n", &"  #{&1}")}

           Delete them and set `migrate? false` on the resource that produced them.
           """
  end

  test "the only migration touching legacy.* is the hand-generated strangler one" do
    # `mix ash_strangler.gen.migration`, not `mix ash.codegen`. That migration
    # does mention `legacy.users` — it declares a view over it, an expression
    # index on it and a notify trigger on it — and that is the one deliberate
    # exception. Any *other* migration mentioning the schema came from codegen,
    # which is the thing this file exists to prevent.
    offenders =
      "priv/repo/migrations/*.exs"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ ~r/\blegacy\./))
      |> Enum.reject(&(Path.basename(&1) =~ "strangler" or File.read!(&1) =~ "ash_strangler"))

    assert offenders == [],
           """
           These migrations touch `legacy.*` and did not come from
           `mix ash_strangler.gen.migration`:

           #{Enum.map_join(offenders, "\n", &"  #{&1}")}
           """
  end
end
