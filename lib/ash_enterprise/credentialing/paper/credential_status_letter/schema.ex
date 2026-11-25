defmodule AshEnterprise.Credentialing.Paper.CredentialStatusLetter.Schema do
  @moduledoc """
  The credential status letter's schema: the clinic writing, the clinician it
  writes to, which credential, its status and its expiry date. The expiry date
  is optional, as a credential may be recorded without one; every other value
  is required, so a letter never prints a blank where the clinic's records
  hold nothing. Labelled in the two locales the kernel formats (`:en`, `:fr`).
  """

  use AshPaper.Schema

  paper do
    key(:credential_status_letter)
    version(1)

    field :clinic, :text, label: [en: "Clinic", fr: "Clinique"]
    field :clinician, :text, label: [en: "Clinician", fr: "Praticien"]
    field :credential, :text, label: [en: "Credential", fr: "Titre"]
    field :status, :text, label: [en: "Status", fr: "Statut"]

    field :expires_on, :date,
      label: [en: "Expires on", fr: "Date d'expiration"],
      required?: false
  end
end
