defmodule AshEnterprise.Integration.GoogleSheets do
  @moduledoc """
  Google Sheets API v4 operations, proxied through the `google-sheet` Nango
  integration (provider base URL `https://sheets.googleapis.com`), on the
  same Google OAuth client as Gmail and Calendar with one scope:
  `https://www.googleapis.com/auth/spreadsheets.readonly`.

  **Read-only, and only reads.** Nothing here writes to a spreadsheet: the
  scope could not, and no write operation is declared. A vertical that keeps
  its source of record in a spreadsheet (a finance team's ledger export, a
  price list) reads it through this resource and lands what it reads in its
  own raw layer; nothing ever writes back to the sheet.

    * `batch_get_values` — `spreadsheets.values.batchGet`. Body:
      `spreadsheetId`, `valueRanges` (one per requested range, in request
      order: `range`, `majorDimension`, `values` — rows of cells, trailing
      empty cells and rows omitted).

  Numbers decode as `Decimal` (`numbers: :decimal`): a sheet's amounts are
  often money, and `UNFORMATTED_VALUE` returns them as JSON numbers, which would
  otherwise pass through a float. Ask for `SERIAL_NUMBER` dates: they are
  unambiguous, where `FORMATTED_STRING` depends on the sheet's locale.

  No table: an operation resource holds actions, not rows. Ownership `:none`
  makes the policy question "may this actor call Sheets at all", answered by
  a global read grant on this resource.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    extensions: [AshEnterprise.Integration.Nango.Operations]

  # Generic actions only and no rows, but the platform's system attributes are
  # still fields, which trips Ash's primary-key check for stored resources.
  resource do
    require_primary_key? false
  end

  nango do
    integration "google-sheet"
    errors :google

    operation :batch_get_values,
              :get,
              "/v4/spreadsheets/{spreadsheet_id}/values:batchGet" do
      description "spreadsheets.values.batchGet: the cell values of one or more ranges."
      numbers(:decimal)

      param :spreadsheet_id, :string, in: :path, allow_nil?: false
      param :ranges, {:array, :string}, as: "ranges", allow_nil?: false

      param :value_render_option, :string,
        as: "valueRenderOption",
        constraints: [match: ~r/\A(FORMATTED_VALUE|UNFORMATTED_VALUE|FORMULA)\z/]

      param :date_time_render_option, :string,
        as: "dateTimeRenderOption",
        constraints: [match: ~r/\A(SERIAL_NUMBER|FORMATTED_STRING)\z/]

      param :major_dimension, :string,
        as: "majorDimension",
        constraints: [match: ~r/\A(ROWS|COLUMNS)\z/]
    end
  end
end
