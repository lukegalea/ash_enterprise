defmodule AshEnterprise.Audit.ExportTest do
  @moduledoc """
  The auditor's sample: a window of the trail, as a file, without engineering
  help.

  The properties worth pinning are not about CSV formatting. They are that the
  export is scoped by the same authorization as every other read, and that it
  carries enough to be re-verified by whoever receives it — an export that omits
  the chain columns is a list of assertions rather than evidence.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Audit.Export
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor

  setup do
    Correlation.start_new()
    %{acme: Ash.UUID.generate(), globex: Ash.UUID.generate()}
  end

  defp create_bu(name, org) do
    BusinessUnit
    |> Ash.Changeset.for_create(:create, %{name: name},
      authorize?: false,
      tenant: org,
      actor: SystemActor.seed()
    )
    |> Ash.create!()
  end

  defp window do
    {DateTime.add(DateTime.utc_now(), -1, :hour), DateTime.add(DateTime.utc_now(), 1, :hour)}
  end

  defp lines(tenant) do
    {from, to} = window()

    from
    |> Export.stream(to, actor: SystemActor.system(), tenant: tenant)
    |> Enum.to_list()
  end

  test "the header names every column, in order" do
    {from, to} = window()

    [header | _] =
      from |> Export.stream(to, actor: SystemActor.system(), tenant: nil) |> Enum.to_list()

    assert String.trim(header) == Enum.map_join(Export.columns(), ",", &to_string/1)
  end

  test "the chain columns are present, so the recipient can re-verify it" do
    for column <- [:sequence, :previous_hash, :hash] do
      assert column in Export.columns()
    end
  end

  test "one line per event in the window, after the header", ctx do
    create_bu("First", ctx.acme)
    create_bu("Second", ctx.acme)

    assert length(lines(ctx.acme)) == 3
  end

  test "the export is scoped exactly as the reader is", ctx do
    create_bu("Ours", ctx.acme)
    create_bu("Theirs", ctx.globex)
    create_bu("Ours again", ctx.acme)

    assert length(lines(ctx.acme)) == 3
    assert length(lines(ctx.globex)) == 2

    # No tenant means every tenant. Deliberately available, deliberately not the
    # thing a customer's auditor is handed.
    assert length(lines(nil)) == 4
  end

  test "an ungranted reader exports nothing rather than everything", ctx do
    create_bu("Ours", ctx.acme)

    {from, to} = window()

    # A filter check narrows rather than refuses, so the failure mode to guard
    # against is an empty-but-successful export -- not an exception.
    assert [_header] =
             from |> Export.stream(to, actor: nil, tenant: ctx.acme) |> Enum.to_list()
  end

  test "values containing commas are quoted rather than shifting the columns", ctx do
    create_bu("Ops, Finance and Legal", ctx.acme)

    [_header | rows] = lines(ctx.acme)

    # The business unit name lands in `data`, which is not a column -- but the
    # resource module name and changed-attribute list are, and the quoting is
    # shared. Assert the invariant that matters: every row has the same number
    # of fields as the header.
    expected = length(Export.columns())

    for row <- rows do
      assert fields(row) == expected
    end
  end

  test "to_file/4 writes what stream/3 produces", ctx do
    create_bu("First", ctx.acme)
    {from, to} = window()

    path = Path.join(System.tmp_dir!(), "audit-export-#{System.unique_integer([:positive])}.csv")
    on_exit(fn -> File.rm(path) end)

    count = Export.to_file(path, from, to, actor: SystemActor.system(), tenant: ctx.acme)

    assert count == 1
    contents = File.read!(path)
    assert contents =~ "sequence,occurred_at"
    assert length(String.split(String.trim(contents), "\n")) == 2
  end

  # Counts CSV fields, respecting quotes.
  defp fields(row) do
    row
    |> String.trim()
    |> String.graphemes()
    |> Enum.reduce({1, false}, fn
      "\"", {count, quoted?} -> {count, not quoted?}
      ",", {count, false} -> {count + 1, false}
      _, acc -> acc
    end)
    |> elem(0)
  end
end
