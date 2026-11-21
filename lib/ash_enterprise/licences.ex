defmodule AshEnterprise.Licences do
  @moduledoc """
  Third-party licences: the packages our applications ship, judged against
  the licence policy (S1-63).

  One resource, `AshEnterprise.Licences.Dependency`: a package at the
  version a `mix.lock` resolves. It carries the nine confirmed licence
  questions: seven in the calibrated `third_party_licence` family, the
  use-restriction question, calibrated in a family of its own, and the
  declaration question, which only the declaration or a person answers. `AshEnterprise.Licences.Rungs` decides
  which rung answers each subject: a single declared SPDX id is answered by
  the declaration (`AshEnterprise.Licences.DeclarationRung`), and only a
  subject without one is sent to a model.
  """

  use Ash.Domain, otp_app: :ash_enterprise

  resources do
    resource AshEnterprise.Licences.Dependency do
      define :register_dependency, action: :register
      define :list_dependencies, action: :read
    end
  end
end
