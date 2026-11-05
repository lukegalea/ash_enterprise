defmodule AshEnterprise.Showcase.Case do
  @moduledoc """
  The credentialing case slice of the showcase (`/app/showcase/credentialing`, beats 10 to
  15): what the tour reads of the BPMN process (`AshEnterprise.Credentialing.CaseProcess`),
  and the one fault control that is its own.

  ## What the tour reads

  `cases/1` reads the cases of the credentials the viewer may read, newest first, each as

      %{instance:, credential:, checks:, requests:, deliveries:, continuations:,
        waiting_for:, review:, timer:}

    * `checks`, each evidence check's invocation (`target`, `status`, `error_code`): a
      check the business refused is `failed` with its code, next to the sibling that
      succeeded (F7);
    * `requests`, the `document.requested` envelopes the case wrote;
    * `deliveries`, the distinct `document.received` envelopes that arrived for the
      credential, and `continuations`, how many times the case was woken by one: however
      many deliveries and in whatever order, one (F6);
    * `waiting_for`, the node ids the case's live tokens are parked at;
    * `review`, the committee's task (`id`, `status`);
    * `timer`, `%{node:, due_at:}` once the case waits for its re-credentialing date: the
      parked token's time plus the timer's duration, read from the event that recorded the
      wait.

  Everything is read for the credentials the viewer may read (`Credentialing.list_credentials`,
  as the viewer), and, as the tour's other reads do, without authorization below that:
  only statuses, codes, ids and times leave, never a document's text or a person's
  words.

  ## The fault control

  `deliver_webhook/3` has the filing system deliver a "document received" webhook for a
  credential `times` times, with the same delivery id: the demo's stand-in for a sender that
  repeats itself. Delivered before the case waits for it, it is the out-of-order delivery. It
  runs through the handler a real webhook would (`AshEnterprise.Credentialing.DocumentWebhook`)
  and refuses unless the demo flag is on (`AshEnterprise.Showcase.fault_controls?/0`).
  """

  require Ash.Query

  alias AshEnterprise.Bpmn.{HumanTask, Instance, ProcessEvent, Token}
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{CaseProcess, Credential, DocumentEvent, DocumentWebhook}
  alias AshEnterprise.Execution
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase
  alias AshEnterprise.Showcase.Credentialing, as: Tour

  # What the engine stores of a subject: `to_string/1` of its module.
  @subject_type to_string(Credential)
  @checks ~w(AshEnterprise.Credentialing.Credential.check_documents
             AshEnterprise.Credentialing.Credential.check_expiry)

  @doc "`actor` opens the credential's case."
  @spec open_case(Ash.UUID.t(), term()) :: {:ok, map()} | {:error, term()}
  def open_case(credential_id, actor),
    do:
      Credentialing.open_case(credential_id,
        actor: actor,
        tenant: ActorContext.tenant(actor)
      )

  @doc "The cases of the credentials `actor` may read, newest first. See the moduledoc."
  @spec cases(term()) :: [map()]
  def cases(actor) do
    tenant = ActorContext.tenant(actor)
    credentials = Map.new(Tour.credentials(actor), &{&1.id, &1})

    case Map.keys(credentials) do
      [] -> []
      ids -> read(ids, credentials, tenant)
    end
  end

  defp read(credential_ids, credentials, tenant) do
    instances =
      Instance
      |> Ash.Query.filter(subject_type == ^@subject_type and subject_id in ^credential_ids)
      |> Ash.Query.select([:id, :status, :outcome, :subject_id, :inserted_at])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(authorize?: false, tenant: tenant)

    ids = Enum.map(instances, & &1.id)

    checks = checks(ids, tenant)

    tokens =
      Token
      |> Ash.Query.filter(instance_id in ^ids)
      |> Ash.read!(authorize?: false, tenant: tenant)
      |> Enum.group_by(& &1.instance_id)

    events =
      ProcessEvent
      |> Ash.Query.filter(instance_id in ^ids)
      |> Ash.read!(authorize?: false, tenant: tenant)
      |> Enum.group_by(& &1.instance_id)

    envelopes = envelopes(credential_ids, tenant)
    reviews = reviews(ids, tenant)

    for instance <- instances do
      credential_id = instance.subject_id
      instance_events = Map.get(events, instance.id, [])
      mine = Map.get(envelopes, credential_id, [])

      %{
        instance: instance,
        credential: Map.get(credentials, credential_id),
        checks: Map.get(checks, instance.id, []),
        requests: Enum.filter(mine, &(&1.type == DocumentEvent.requested())),
        deliveries: Enum.filter(mine, &(&1.type == DocumentEvent.received())),
        continuations: Enum.count(instance_events, &(&1.kind == :message_received)),
        waiting_for: waiting_for(Map.get(tokens, instance.id, [])),
        review: Map.get(reviews, instance.id),
        timer: timer(Map.get(tokens, instance.id, []), instance_events)
      }
    end
  end

  defp checks([], _tenant), do: %{}

  defp checks(instance_ids, tenant) do
    Execution.list_invocations!(
      authorize?: false,
      tenant: tenant,
      query: [
        filter: [process_instance_id: [in: instance_ids], target: [in: @checks]],
        sort: [created_on: :asc]
      ]
    )
    |> Enum.group_by(& &1.process_instance_id)
  end

  defp envelopes(credential_ids, tenant) do
    subjects = Enum.map(credential_ids, &to_string/1)

    DocumentEvent
    |> Ash.Query.filter(subject in ^subjects)
    |> Ash.Query.select([:id, :event_id, :type, :subject, :time])
    |> Ash.Query.sort(time: :asc)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.group_by(& &1.subject)
  end

  defp reviews(instance_ids, tenant) do
    node = CaseProcess.committee_node()

    HumanTask
    |> Ash.Query.filter(instance_id in ^instance_ids and node_id == ^node)
    |> Ash.Query.select([:id, :instance_id, :status])
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Map.new(&{&1.instance_id, %{id: &1.id, status: &1.status}})
  end

  defp waiting_for(tokens) do
    for token <- tokens, token.status in [:waiting, :active, :executing], do: token.node_id
  end

  # The parked timer token's time plus the duration its wait recorded.
  defp timer(tokens, events) do
    node = CaseProcess.recredential_node()

    with %{status: :waiting, parked_at: %DateTime{} = parked} <-
           Enum.find(tokens, &(&1.node_id == node)),
         %{data: %{"duration" => duration}} when is_binary(duration) <-
           Enum.find(events, &(&1.kind == :node_entered and &1.node_id == node)),
         {:ok, duration} <- Duration.from_iso8601(duration) do
      %{node: node, due_at: DateTime.shift(parked, duration)}
    else
      _no_timer_yet -> nil
    end
  end

  @doc """
  The filing system delivers the "document received" webhook for `credential_id` `times`
  times, under one delivery id. `{:ok, [:received, :duplicate, ...]}`, one answer per
  delivery.
  """
  @spec deliver_webhook(Ash.UUID.t(), Ash.UUID.t(), pos_integer()) ::
          {:ok, [:received | :duplicate]} | {:error, term()}
  def deliver_webhook(credential_id, tenant, times) when times in 1..5 do
    if Showcase.fault_controls?() do
      delivery = "delivery:" <> Ash.UUIDv7.generate()
      answers = for _ <- 1..times, do: DocumentWebhook.deliver(tenant, credential_id, delivery)

      case Enum.find(answers, &match?({:error, _}, &1)) do
        nil -> {:ok, answers}
        error -> error
      end
    else
      {:error, :fault_controls_off}
    end
  end
end
