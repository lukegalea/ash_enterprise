defmodule AshEnterprise.SystemOne.BandTableCertification.StatusOnly do
  @moduledoc """
  The preparation of `AshEnterprise.SystemOne.BandTableCertification`'s
  `:for_definition` read, which crosses tenants: every field of a row it returns,
  except whether it is in force, when it was made and what it certifies, is withheld
  as `%Ash.ForbiddenField{}`. It applies to the rows after they are read, so a
  caller's `select` or `load` cannot widen it.

  What a certification certifies includes the instrument its calibration run
  measured: each row carries it as the metadata `:certified_instrument`
  (`%{model_digest:, runtime_version:}`, read from the run in the certifier's
  tenant), or nil when the row names no run. A table certified for one model
  says nothing about another, so whoever acts on the table compares it with the
  instrument that answered (`AshEnterprise.Quality.Gate.certified?/3`).
  """

  use Ash.Resource.Preparation

  require Ash.Query

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.CalibrationRun

  @shown [
    :id,
    :status,
    :certified_at,
    :definition_key,
    :definition_version,
    :content_hash,
    :family
  ]

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn query, records ->
      with {:ok, instruments} <- instruments(records) do
        {:ok,
         Enum.map(records, fn record ->
           record
           |> Ash.Resource.put_metadata(
             :certified_instrument,
             Map.get(instruments, {record.organization_id, record.calibration_run_id})
           )
           |> withhold(query.resource)
         end)}
      end
    end)
  end

  # The instrument each certification's run measured, read in the tenant the
  # run and its certification were recorded in.
  defp instruments(records) do
    records
    |> Enum.filter(& &1.calibration_run_id)
    |> Enum.group_by(& &1.organization_id, & &1.calibration_run_id)
    |> Enum.reduce_while({:ok, %{}}, fn {tenant, ids}, {:ok, acc} ->
      CalibrationRun
      |> Ash.Query.filter(id in ^Enum.uniq(ids))
      |> Ash.Query.select([:id, :model_digest, :runtime_version])
      |> Ash.read(tenant: tenant, actor: SystemActor.system())
      |> case do
        {:ok, runs} ->
          {:cont,
           {:ok,
            Enum.reduce(runs, acc, fn run, acc ->
              Map.put(acc, {tenant, run.id}, %{
                model_digest: run.model_digest,
                runtime_version: run.runtime_version
              })
            end)}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp withhold(record, resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reject(&(&1.name in @shown))
    |> Enum.reduce(record, fn attribute, record ->
      Map.put(record, attribute.name, %Ash.ForbiddenField{
        field: attribute.name,
        type: :attribute
      })
    end)
  end
end
