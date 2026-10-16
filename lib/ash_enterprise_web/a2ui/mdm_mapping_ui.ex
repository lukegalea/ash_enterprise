defmodule AshEnterpriseWeb.A2ui.MdmMappingUI do
  @moduledoc """
  A2UI surface over the MDM mapping version chain — the no-deploy
  onboarding answer to "which mapping version is live, and what changed".

  The version chain (`root_id`/`supersedes_id`/`version`) is the drill:
  retired versions stay readable, activation supersedes, nothing is
  overwritten. A row opens its detail — the field rules, the content hash
  batches pin, the activation note — and links the version it supersedes.

  Read-only by decision: mappings are drafted, validated and activated
  through their own person-gated actions (ImportLive, the code interface),
  never through a surface.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Mdm.Mapping)
    surface_id("mdm_mappings")
    title("MDM mappings")
    record_label("mapping version")

    context :mapping do
      resource(AshEnterprise.Mdm.Mapping)
      picker(false)
    end

    query :default do
      sortable([:status, :version, :modified_on])
      default_sort(status: :desc, version: :desc)
      page_size(25)
    end

    component :table do
      fields([:source, :stream, :target_resource, :direction, :status, :version])
      read_action(:read)
      query(:default)
      select_context(:mapping)

      row_layout do
        title(:target_resource)
        badge(:status)
        meta([:direction, :source, :stream, :version])
        columns(2)
      end
    end

    component :detail, :mapping_detail do
      context(:mapping)

      fields([
        :target_resource,
        :direction,
        :source,
        :stream,
        :status,
        :version,
        :previous_version,
        :rule_summary,
        :content_hash,
        :activation_note
      ])
    end

    field :status do
      label("Lifecycle")
    end

    field :previous_version do
      label("Supersedes")
      link({:mdm_mappings, :supersedes_id})
    end

    field :rule_summary do
      label("Field rules")
    end

    field :content_hash do
      label("Content hash (batches pin this)")
    end

    field :activation_note do
      label("Activation note")
    end
  end
end
