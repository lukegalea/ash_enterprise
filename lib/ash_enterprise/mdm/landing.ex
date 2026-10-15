defmodule AshEnterprise.Mdm.Landing do
  @moduledoc """
  The bizev declaration for MDM ingress: ONE fixed source/stream pair —
  `:manual_csv` / `:upload` — declared at compile time.

  The per-customer dimension is data, never atoms: the customer/dataset
  slug rides as a STRING on `ImportBatch.source_slug` and in each row's
  `source_metadata`, and the `external_id` is `"org:slug:row_key"` — so two
  organizations landing the same row never collide into one temporal
  record, and `String.to_atom` never sees CS input (Iron Law #10). A new
  customer is a Mapping row, not a DSL declaration and not a deploy.
  """

  use AshDiscreteBusinessEvents, domains: [AshEnterprise.Mdm]

  business_events do
    source :manual_csv do
      # The adapter boundary has no callbacks yet (BIZEV-7); a CSV upload
      # lands row-by-row through the land action, not an adapter pull.
      adapter(AshEnterprise.Mdm.ManualCsvAdapter)
      region(:us)

      stream :upload do
      end
    end
  end

  defmodule ManualCsvAdapter do
    @moduledoc """
    Placeholder module satisfying the source schema's adapter shape for
    the CS-upload boundary. The behaviour grows callbacks at BIZEV-7;
    an upload lands through `AshEnterprise.Mdm.Landing.land_row/4`, never an
    adapter pull.
    """
  end

  @doc """
  Lands one uploaded row for `tenant`, under `slug`, with the tenant's
  region/residency declaration. Zone admission is bizev's land-path change
  (ADR 0042) — the tag here must agree with the region or land is refused.

  Row options: `row_key` (the source's own id for the row; generated when
  the source has none), `fetched_at` (defaults to now — an upload's
  observation instant IS its fetch).
  """
  def land_row(tenant, slug, payload, opts \\ []) when is_map(payload) do
    row_key = opts[:row_key] || Ash.UUID.generate()
    fetched_at = opts[:fetched_at] || DateTime.utc_now()

    # The tenant's zone decides the region (ADR 0042: admission at land).
    # Zone→tenant binding is host configuration — `default_region` under
    # `AshEnterprise.Mdm.Landing` (a lowercase atom) — not a package
    # default. The region and its residency tag stay in bizev's lowercase
    # contract; the ISO mapping happens at the egress disclosure gate.
    region =
      opts[:region] ||
        :ash_enterprise
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:default_region, :us)

    AshEnterprise.Mdm.SourceRecord.land(
      %{
        source: :manual_csv,
        stream: :upload,
        external_id: "#{tenant}:#{slug}:#{row_key}",
        region: region,
        residency_tag: Atom.to_string(region),
        raw_payload: payload,
        source_metadata: %{"tenant" => tenant, "slug" => slug},
        cursor: nil,
        fetched_at: fetched_at
      },
      tenant: tenant,
      authorize?: false
    )
  end
end
