defmodule AshEnterpriseWeb.A2ui.MdmMappingUI do
  @moduledoc """
  A2UI surface over the MDM mapping version chain — the no-deploy
  onboarding answer to "which mapping version is live, and what changed".

  The version chain (`root_id`/`supersedes_id`/`version`) is the drill:
  retired versions stay readable, activation supersedes, nothing is
  overwritten. Read-only: mappings activate and validate through their own
  person-gated actions, never through a surface.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Mdm.Mapping)
    surface_id("mdm_mappings")
    title("MDM mappings")
    record_label("mapping version")

    query :default do
      sortable([:status, :version, :modified_on])
      default_sort(status: :desc, version: :desc)
      page_size(25)
    end

    component :table do
      fields([:source, :stream, :target_resource, :direction, :status, :version])
      read_action(:read)
      query(:default)

      row_layout do
        title(:target_resource)
        badge(:status)
        meta([:direction, :source, :stream, :version])
        columns(2)
      end
    end

    field :status do
      label("Lifecycle")
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.MdmGoldenUI do
  @moduledoc """
  A2UI surface over the canonical Person goldens — the merged view of the
  customer, with its merge lineage readable (`merged`/`master_id`): who
  absorbed whom is a question the row answers.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Canonical.Person)
    surface_id("mdm_golden")
    title("Golden records")
    record_label("golden record")

    query :default do
      sortable([:name, :email, :created_on])
      default_sort(name: :asc)
      page_size(25)
    end

    component :table do
      fields([:name, :email])
      read_action(:goldens)
      query(:default)

      row_layout do
        title(:name)
        meta([:email])
        columns(2)
      end
    end
  end
end
