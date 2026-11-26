defmodule AshEnterpriseWeb.A2ui.CredentialUI do
  @moduledoc """
  The credentialing workspace: the clinic's credentials, soonest to expire first, with the
  clinician each belongs to and whether the registry has activated it.

  The number is a secured column (ADR 0073): a reader without its grant sees it as masked
  text, not empty (`AshEnterpriseWeb.HiddenField`), and
  a sort on it is refused for them (`AshEnterprise.Security.Preparations.SecuredFieldRefs`),
  so the table neither sorts by it by default nor offers it as a sort. A search on it
  matches nothing for that reader. Edit leaves a hidden number as it is: the form sends
  no value for a field its reader could not see, and `Credential.correct` keeps the number
  when none is given.

  **Ask to activate** runs `Credential.request_activation` as the person clicking: the
  request for the governed `activate_credential` (ADR 0055), which waits for a member of
  the credentialing committee other than them to approve it. Edit runs
  `Credential.correct`, the credential's number or expiry date. **Open case** starts the
  credential's case (`Credential.open_case`), the credentialing process, as you.

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

    context :credential do
      resource AshEnterprise.Credentialing.Credential
      picker false
    end

    query :default do
      search_fields [:number]
      sortable [:status, :expires_on]
      default_sort expires_on: :asc
      page_size 25
    end

    component :table do
      fields [:number, :clinician_name, :kind, :status, :expires_on, :registry_reference]
      read_action :read
      query :default
      select_context :credential
      row_actions [:request_activation, :open_case]

      # Titled by the clinician, not the number: a reader without the number's grant would
      # see every card untitled.
      row_layout do
        title :clinician_name
        badge :status
        badge_text pending: "Pending", active: "Active"
        meta [:number, :kind, :expires_on, :registry_reference]
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

    action :open_case do
      label "Open case"
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
