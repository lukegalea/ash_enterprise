defmodule Battery.BusinessEvents.Host do
  @moduledoc """
  The battery's `business_events` host: two external sources (each in its
  own identity namespace — the first element of the SourceRecord identity
  tuple) and one mapping per source stream. Mappings are data: published
  into content-hashed MappingVersion artifacts, applied by the pure run
  path.
  """

  use AshDiscreteBusinessEvents, domains: [Battery.Domain]

  business_events do
    source :salesforce do
      adapter(Battery.BusinessEvents.StubAdapter)
      auth(:nango, provider: "salesforce")
      cursor(:system_modstamp)
      region(:us)
      rate_budget(daily: 10_000)

      stream :vendor do
        select "SELECT Id, VendorName, City, Tier, SystemModstamp FROM Vendor__c"
      end
    end

    source :file_import do
      adapter(Battery.BusinessEvents.StubAdapter)
      auth(:shared_secret, provider: "file_drop")
      cursor(:batch_seq)
      region(:us)
      rate_budget(daily: 10_000)

      stream :vendor do
        select "SELECT Id, VendorName, City, Tier, SystemModstamp FROM vendor_rows"
      end
    end

    mapping :salesforce_vendor_sync do
      source {:salesforce, :vendor}

      map(:vendor_name, from: "VendorName", type: :string)
      map(:city, from: "City", type: :string)
      map(:tier, from: "Tier", type: :string)
      map(:occurred_at, from: "SystemModstamp", type: :utc_datetime_usec)
    end

    mapping :file_import_vendor_sync do
      source {:file_import, :vendor}

      map(:vendor_name, from: "VendorName", type: :string)
      map(:city, from: "City", type: :string)
      map(:tier, from: "Tier", type: :string)
      map(:occurred_at, from: "SystemModstamp", type: :utc_datetime_usec)
    end
  end
end
