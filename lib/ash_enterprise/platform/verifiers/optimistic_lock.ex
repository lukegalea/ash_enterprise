defmodule AshEnterprise.Platform.Verifiers.OptimisticLock do
  @moduledoc """
  Compile-time guard on the platform's optimistic lock (ADR 0059).

  `AshEnterprise.Platform.Resource` puts `optimistic_lock(:version_number)` on
  every update action. A strangled read model that projects `version_number`
  as a constant has no stored version to lock against or increment: the lock
  would filter on the constant and then try to write the next value into a
  view. Such a resource must say so with `optimistic_lock?: false`, and this
  verifier refuses it otherwise, so the exemption is a declaration in the
  resource rather than something discovered at the first write.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    locked? = Verifier.get_option(dsl, [:platform], :optimistic_lock?, true)

    if locked? and projects_constant_version?(dsl) do
      {:error,
       Spark.Error.DslError.exception(
         module: Verifier.get_persisted(dsl, :module),
         path: [:platform, :optimistic_lock?],
         message:
           "version_number is projected as a strangler constant, so there is no stored " <>
             "version to lock; set `optimistic_lock?: false` on this resource"
       )}
    else
      :ok
    end
  end

  defp projects_constant_version?(dsl) do
    # A resource without the strangler section has no entities there, so this
    # is `[]` for every resource that is not a strangled read model.
    Enum.any?(AshStrangler.Info.constants(dsl), &(&1.attribute == :version_number))
  end
end
