defmodule AshEnterprise.Exports do
  @moduledoc """
  Bulk export out: a tenant's data as CSV, under the same policies as every
  other read (docs/runbooks/exports.md).

    * `AshEnterprise.Exports.Export`: the export privilege. Opening an export is a
      generic action on a resource with no rows, so "may export" is one more
      grantable `(resource, verb)` row, held by default by the tenant's
      Administrator role and nobody else.
    * `AshEnterprise.Exports.Csv`: which resources are exportable, and the CSV
      stream of one, read in keyset pages as the requester.

  `GET /api/exports/:type` (`AshEnterpriseWeb.ExportController`) is the way in, with
  a bearer API key. The A2UI surfaces export their own tables through ash_a2ui's
  `export` block, re-read as the signed-in person; this domain is the bulk path.
  """

  use Ash.Domain, otp_app: :ash_enterprise

  resources do
    resource AshEnterprise.Exports.Export do
      define :open_export, action: :open, args: [:type]
    end
  end
end
