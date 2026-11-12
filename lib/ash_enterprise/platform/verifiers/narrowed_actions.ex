defmodule AshEnterprise.Platform.Verifiers.NarrowedActions do
  @moduledoc """
  Compile-time guard on `human_only`, `machinery_only` (ADR 0059) and
  `changes_authority` (ADR 0043).

  - Every listed action must exist. A misspelt name would narrow nothing and
    look, in review, as if it narrowed something.
  - No action may be both: one says only a person may run it, the other that
    no person may.
  - A `machinery_only` action may not also be `self_service`: self-service is
    a grant path in the union, and the union does not apply to machinery
    actions, so the declaration would be dead.
  - An `engine_only` action (ADR 0069) may be none of `human_only`,
    `machinery_only` or `self_service`: each says someone other than the
    engines runs it.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    resource = Verifier.get_persisted(dsl, :module)
    human_only = Verifier.get_option(dsl, [:platform], :human_only, [])
    machinery_only = Verifier.get_option(dsl, [:platform], :machinery_only, [])
    self_service = Verifier.get_option(dsl, [:platform], :self_service, [])
    changes_authority = Verifier.get_option(dsl, [:platform], :changes_authority, [])
    engine_only = Verifier.get_option(dsl, [:platform], :engine_only, [])

    problems =
      missing(dsl, :human_only, human_only) ++
        missing(dsl, :machinery_only, machinery_only) ++
        missing(dsl, :changes_authority, changes_authority) ++
        missing(dsl, :engine_only, engine_only) ++
        both(machinery_only, human_only, "is both human_only and machinery_only") ++
        both(
          machinery_only,
          self_service,
          "is machinery_only and self_service; the grant union, self-service included, " <>
            "does not apply to a machinery action"
        ) ++
        engine_only_conflicts(engine_only, human_only, machinery_only, self_service)

    case problems do
      [] ->
        :ok

      [{option, message} | _] ->
        {:error,
         Spark.Error.DslError.exception(
           module: resource,
           path: [:platform, option],
           message: message
         )}
    end
  end

  defp missing(dsl, option, names) do
    for name <- names, is_nil(Ash.Resource.Info.action(dsl, name)) do
      {option, "#{option} #{inspect(name)}: no such action"}
    end
  end

  defp engine_only_conflicts(engine_only, human_only, machinery_only, self_service) do
    for {other, label} <- [
          {human_only, "human_only"},
          {machinery_only, "machinery_only"},
          {self_service, "self_service"}
        ],
        name <- engine_only,
        name in other do
      {:engine_only, "engine_only #{inspect(name)} is also #{label}; only the engines run it"}
    end
  end

  defp both(machinery_only, other, message) do
    for name <- machinery_only, name in other do
      {:machinery_only, "machinery_only #{inspect(name)} #{message}"}
    end
  end
end
