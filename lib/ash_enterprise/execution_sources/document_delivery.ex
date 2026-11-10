defmodule AshEnterprise.ExecutionSources.DocumentDelivery do
  @moduledoc """
  The filing system's "document received" webhook deliveries
  (`AshEnterprise.Credentialing.DocumentEvent`, type `document.received`) as observation
  entries, for the credential a process run in the trace is about. An entry says what
  kind of document arrived and when; the envelope's `data` beyond that kind, and
  anything the sender's request carried (body, headers), is never in it.

  ## What is recorded about a repeat

  A delivery is one row per sender and delivery id: the handler
  (`AshEnterprise.Credentialing.DocumentWebhook`) answers a repeat `:duplicate` without
  writing anything. The trace therefore shows each delivery once and cannot show that one
  came twice; it never infers a repeat.

  ## Read only through a process run the viewer may read

  A delivery is keyed by the credential it is about, not by the run. This source reads, as
  the viewer in their tenant, the runs in the trace that are about a credential, and then
  the deliveries for those credentials, also as the viewer. A viewer who cannot read the
  run, or the deliveries, sees none. A delivery's parent is the run when exactly one run
  in the trace is about its credential; with several, the delivery is not placed under
  any of them.
  """

  @behaviour AshAgent.Execution.Source

  import Ash.Expr, only: [expr: 1]

  alias AshAgent.Execution.Source
  alias AshEnterprise.Bpmn.Instance
  alias AshEnterprise.Credentialing.{Credential, DocumentEvent}
  alias AshEnterprise.ExecutionSources

  require Ash.Query

  @credential to_string(Credential)
  @kind_limit 80

  @impl true
  def read(scope, opts) do
    with {:ok, runs} <- readable_runs(ExecutionSources.uuids(scope, :process_instance), opts),
         by_credential = Enum.group_by(runs, & &1.subject_id, & &1.id),
         {:ok, rows, next} <-
           ExecutionSources.read(
             DocumentEvent,
             [subject: Map.keys(by_credential)],
             opts,
             time: :time,
             where: expr(type == ^DocumentEvent.received())
           ) do
      {:ok, Enum.map(rows, &Ash.Resource.put_metadata(&1, :run_ids, by_credential[&1.subject])),
       next}
    end
  end

  @doc """
  Whether the viewer may read a process run about the credential `delivery` is for,
  so a delivery is opened only where the trace would show it.
  """
  @spec readable?(DocumentEvent.t(), keyword()) :: boolean()
  def readable?(%{type: type} = delivery, opts) do
    case type == DocumentEvent.received() && Ecto.UUID.cast(delivery.subject) do
      {:ok, credential_id} ->
        Instance
        |> Ash.Query.for_read(:read, %{}, actor: opts[:actor], tenant: opts[:tenant])
        |> Ash.Query.filter(subject_type == ^@credential and subject_id == ^credential_id)
        |> Ash.Query.limit(1)
        |> Ash.exists?()

      _not_a_received_delivery ->
        false
    end
  end

  @doc "The kind of document a delivery names, or nil."
  @spec document_kind(DocumentEvent.t()) :: String.t() | nil
  def document_kind(%{data: %{"kind" => kind}}) when is_binary(kind), do: kind
  def document_kind(_delivery), do: nil

  defp readable_runs([], _opts), do: {:ok, []}

  defp readable_runs(ids, opts) do
    Instance
    |> Ash.Query.for_read(:read, %{}, actor: opts[:actor], tenant: opts[:tenant])
    |> Ash.Query.filter(id in ^ids and subject_type == ^@credential)
    |> Ash.Query.select([:id, :subject_id])
    |> Ash.read()
    |> case do
      {:ok, runs} ->
        {:ok,
         for(
           run <- runs,
           run.subject_id,
           do: %{id: run.id, subject_id: to_string(run.subject_id)}
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def to_entries(rows), do: Enum.map(rows, &entry/1)

  defp entry(delivery) do
    Source.entry(
      at: delivery.time,
      kind: :observation,
      status: :succeeded,
      source_ref: Source.ref(:document_delivery, delivery.id),
      parent_ref: parent(delivery.__metadata__[:run_ids]),
      summary: summary(document_kind(delivery))
    )
  end

  defp parent([run_id]), do: Source.ref(:process_instance, run_id)
  defp parent(_none_or_several), do: nil

  defp summary(nil), do: "document received"
  defp summary(kind), do: "document received: #{truncate(kind)}"

  # The kind is the sender's string; the summary shows at most @kind_limit characters of it.
  defp truncate(kind) do
    if String.length(kind) > @kind_limit,
      do: String.slice(kind, 0, @kind_limit - 1) <> "…",
      else: kind
  end
end
