defmodule AshEnterprise.Integration.Landing.Scoped do
  @moduledoc """
  The lander: seals each fetched record into `AshEnterprise.Ingestion.SourceObject`
  under the erasure scope of the linked account it came through (ADR 0024).

    * `open_scope/2` — `AshEnterprise.Erasure.ensure_scope/4` for
      `(:connection, <linked account uuid>)`, as the `oban` system actor (an
      adapter is infrastructure; no human opens a scope by syncing). A scope
      that has been shredded is refused with `:scope_shredded`, never reopened.
    * `land/2` — `SourceObject.land_under/3` with the scope's id. The upsert on
      `(external_system, external_id)` keeps re-landing idempotent.

  ## Refusals, reduced to atoms

  Errors never leave this module verbatim: an Ash error from a failed write can
  quote the payload it was writing, and adapters persist their outcome in Oban.

  | Reason | Meaning |
  |---|---|
  | `:scope_shredded` | the scope was shredded (before the step, or by a shred racing it) |
  | `:cross_scope_landing` | a row with this `(external_system, external_id)` already exists under a *different* scope; it is never silently re-scoped |
  | `:landing_failed` | anything else |
  """

  @behaviour AshEnterprise.Integration.Landing

  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.{Landing, SourceRecord}
  alias AshEnterprise.Platform.SystemActor

  @impl Landing
  def open_scope(ref, attrs) when is_binary(ref) do
    case Erasure.ensure_scope(Landing.scope_kind(), ref, attrs, actor: SystemActor.oban()) do
      {:ok, %Scope{status: :active} = scope} -> {:ok, scope}
      {:ok, %Scope{status: :shredded}} -> {:error, :scope_shredded}
      {:error, _error} -> {:error, :scope_unavailable}
    end
  end

  @impl Landing
  def land(%SourceRecord{} = record, ref) when is_binary(ref) do
    with {:ok, scope} <- open_scope(ref, %{}) do
      land(record, scope)
    end
  end

  def land(%SourceRecord{} = record, %Scope{id: scope_id}) do
    scope_id
    |> SourceObject.land_under(attributes(record), authorize?: false)
    |> case do
      {:ok, source_object} -> {:ok, source_object}
      {:error, error} -> {:error, reason(error)}
    end
  end

  defp attributes(record) do
    %{
      external_system: record.external_system,
      external_id: record.external_id,
      raw_payload: record.raw_payload,
      source_metadata: Map.put(record.source_metadata || %{}, "stream", record.stream),
      cursor: record.cursor,
      fetched_at: record.fetched_at || DateTime.utc_now()
    }
  end

  @doc false
  # Structural reasons only; see the moduledoc.
  def reason(error) do
    errors = flatten(error)

    cond do
      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) -> :cross_scope_landing
      Enum.any?(errors, &shredded?/1) -> :scope_shredded
      true -> :landing_failed
    end
  end

  defp flatten(%{errors: errors}) when is_list(errors), do: Enum.flat_map(errors, &flatten/1)
  defp flatten(error), do: [error]

  # SealUnderScope's refusal: an error on `erasure_scope_id` whose message
  # says the scope is shredded. Matched on the field and the message template,
  # which carry no content.
  defp shredded?(%{field: :erasure_scope_id, message: message}) when is_binary(message),
    do: message =~ "shredded"

  defp shredded?(_error), do: false
end
