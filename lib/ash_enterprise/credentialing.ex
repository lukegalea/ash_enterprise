defmodule AshEnterprise.Credentialing do
  @moduledoc """
  A synthetic clinic onboarding its clinicians: the worked example for governed
  invocation (ADR 0055). Everything in it is illustrative; no thresholds, wording or
  records are drawn from any real credentialing practice.

  | Resource | Source | What it is |
  |---|---|---|
  | `Clinic` | CDM `Account` | A clinic that employs clinicians |
  | `Clinician` | CDM `Contact` | A person the clinic is onboarding |
  | `Credential` | invented (see its moduledoc) | A licence or certification awaiting activation |

  The committee's review of an activation is a `AshEnterprise.Bpmn.HumanTask`, which
  already adopts the CDM `Task`; this domain adds no task resource of its own.

  `Credential.activate_credential` is the governed act. It reaches an outside registry
  (`AshEnterprise.Credentialing.Registry`, a stub), asks a committee member other than
  the requester to approve, and is reached only through `AshEnterprise.Execution.invoke/4`:
  there is no code interface for it here.

  `AshEnterprise.Credentialing.DemoData` seeds the clinic (`mix ash_enterprise.demo`).
  """

  use Ash.Domain, otp_app: :ash_enterprise

  resources do
    resource AshEnterprise.Credentialing.Clinic do
      define :register_clinic, action: :register, args: [:name]
      define :list_clinics, action: :read
    end

    resource AshEnterprise.Credentialing.Clinician do
      define :register_clinician, action: :register
      define :list_clinicians, action: :read
    end

    resource AshEnterprise.Credentialing.Credential do
      define :record_credential, action: :record
      define :get_credential, action: :read, get_by: [:id]
      define :list_credentials, action: :read
      define :lookup_activation, action: :lookup_activation, args: [:credential_id]
    end
  end
end
