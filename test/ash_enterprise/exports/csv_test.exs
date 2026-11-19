defmodule AshEnterprise.Exports.CsvTest do
  @moduledoc """
  The cell contract of the bulk export (`AshEnterprise.Exports.Csv`): a withheld
  field is an empty cell, a spreadsheet formula is written as text, and the
  exportable set is the declared list of API-exposed resources.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Exports.Csv

  test "a field the reader may not see is an empty cell, as is a missing value" do
    assert Csv.cell(%Ash.ForbiddenField{field: :number, type: :attribute}) == ""
    assert Csv.cell(%Ash.NotLoaded{}) == ""
    assert Csv.cell(nil) == ""
  end

  test "a text cell that a spreadsheet would evaluate is written as text" do
    for lead <- ["=", "+", "-", "@", "\t", "\r"] do
      assert Csv.cell(lead <> "HYPERLINK(\"x\")") == "'" <> lead <> "HYPERLINK(\"x\")"
    end

    assert Csv.cell(Ash.CiString.new("=1+1")) == "'=1+1"
    assert Csv.cell("Sales") == "Sales"

    # Numbers are values, not formulas.
    assert Csv.cell(-5) == "-5"
    assert Csv.cell(Decimal.new("-1.50")) == "-1.50"
  end

  test "a line quotes what RFC 4180 needs quoted and ends in CRLF" do
    assert Csv.line(["a", "b,c", ~s(say "hi"), "two\nlines"]) ==
             ~s(a,"b,c","say ""hi""","two\nlines") <> "\r\n"
  end

  test "values keep a stable text form" do
    assert Csv.cell(~U[2026-11-17 10:00:00.000000Z]) == "2026-11-17T10:00:00.000000Z"
    assert Csv.cell(~D[2026-11-17]) == "2026-11-17"
    assert Csv.cell(true) == "true"
    assert Csv.cell(:owner) == "owner"
    assert Csv.cell(%{"a" => 1}) == ~s({"a":1})
  end

  test "only the declared API-exposed collections are exportable" do
    assert Csv.types() == ["business_units", "positions", "teams"]
    assert Csv.resource_for("teams") == AshEnterprise.Accounts.Team
    assert Csv.resource_for("users") == nil
    assert Csv.resource_for("event_logs") == nil

    for type <- Csv.types() do
      resource = Csv.resource_for(type)

      assert AshJsonApi.Resource.Info.type(resource),
             "#{inspect(resource)} is exportable but not exposed over JSON:API"

      assert Ash.Resource.Info.action(resource, :list).pagination.keyset?
    end
  end
end
