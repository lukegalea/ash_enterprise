defmodule AshEnterpriseWeb.A2ui.CredentialUI do
  @moduledoc """
  The credentialing workspace: the clinic's credentials, by number, with the clinician
  each belongs to and whether the registry has activated it.

  **Ask to activate** runs `Credential.request_activation` as the person clicking: the
  request for the governed `activate_credential` (ADR 0055), which waits for a member of
  the credentialing committee other than them to approve it. Edit runs
  `Credential.correct`, the credential's number or expiry date.

  A credential's detail shows what the licence reader found in its documents, each
  finding with the lines it cites (`Credential.document_findings`).

  Served at `/app/credentialing`; `/app/r/credentials/:id` deep-links one credential.
  The guided tour over it is `/app/showcase/credentialing`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Credentialing.Credential
    surface_id "credentials"
    title "Credentials"
    record_label "credential"
    spec_version "1.0"

    context :credential do
      resource AshEnterprise.Credentialing.Credential
      picker false
    end

    query :default do
      search_fields [:number]
      sortable [:number, :status, :expires_on]
      default_sort number: :asc
      page_size 25
    end

    component :table do
      fields [:number, :clinician_name, :kind, :status, :expires_on, :registry_reference]
      read_action :read
      query :default
      select_context :credential
      row_actions [:request_activation]

      row_layout do
        title :number
        badge :status
        badge_text pending: "Pending", active: "Active"
        meta [:clinician_name, :kind, :expires_on, :registry_reference]
        columns 2
      end
    end

    component :detail, :credential_detail do
      context :credential

      fields [
        :number,
        :kind,
        :status,
        :expires_on,
        :registry_reference,
        :activated_at,
        :document_findings
      ]
    end

    component :form do
      fields [:number, :expires_on]
      update_action :correct
    end

    action :request_activation do
      label "Ask to activate"
      visible_when status: :pending
    end

    field :clinician_name do
      label "Clinician"
      source [:clinician, :last_name]
    end

    field :registry_reference do
      label "Registry reference"
    end

    field :expires_on do
      label "Expires"
    end

    field :document_findings do
      label "Found in its documents"
    end
  end
end
