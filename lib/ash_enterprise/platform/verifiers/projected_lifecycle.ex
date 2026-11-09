defmodule AshEnterprise.Platform.Verifiers.ProjectedLifecycle do
  @moduledoc """
  `state_machine?: false` is a claim about the data: this application does not own
  the lifecycle, because `lifecycle_status` is a read-only strangler projection of a
  legacy value. Without that mapping nothing would guard the column at all, so the
  option is refused.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    if Verifier.get_option(dsl, [:platform], :state_machine?, true) or read_only_projection?(dsl) do
      :ok
    else
      {:error,
       Spark.Error.DslError.exception(
         module: Verifier.get_persisted(dsl, :module),
         path: [:platform, :state_machine?],
         message:
           "state_machine?: false needs `lifecycle_status` to be a read-only strangler " <>
             "mapping; a lifecycle this application owns must be driven by the state machine"
       )}
    end
  end

  defp read_only_projection?(dsl) do
    case AshStrangler.Info.source(dsl) do
      %{mappings: mappings} ->
        Enum.any?(mappings, &(Map.get(&1, :attribute) == :lifecycle_status and &1.read_only?))

      _ ->
        false
    end
  end
end
