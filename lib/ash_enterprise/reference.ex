defmodule AshEnterprise.Reference do
  @moduledoc """
  Scaffolded by `mix cdm.gen.resource`. Replace this with a real domain
  moduledoc once the domain holds more than a generated starting point --
  see the other domains in lib/ash_enterprise/ for the expected shape
  (what is exposed over the public APIs and why, what is deliberately not).
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource AshEnterprise.Reference.Currency
    resource AshEnterprise.Reference.TimeZoneDefinition
    resource AshEnterprise.Reference.LanguageLocale
  end
end
