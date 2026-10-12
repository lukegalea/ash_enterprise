defmodule AshEnterprise.Canonical.Projections.Gmail do
  @moduledoc """
  Raw → canonical projection for Gmail (epic E4, ADR 0037's host-declared
  pattern): landed `gmail.messages` records become
  `AshEnterprise.Canonical.Conversation` (one per Gmail thread),
  `AshEnterprise.Canonical.Message` (one per message) and
  `AshEnterprise.Canonical.Person` (one per email address: v1 linkage is the
  address and nothing else, no fuzzy resolution).

  ## Gated by zone admission, deny by default (ADR 0042)

  Every landed record is put to the configured
  `AshEnterprise.Canonical.Projections.Gmail.ZoneGate` before anything is
  derived from it. The default gate admits nothing, so out of the box this
  module reads, refuses and writes **no** canonical row. A refused record is
  counted, never projected and never partially projected.

  ## Deterministic

  Everything projected is a function of the admitted payloads and the replay
  context: no wall clock, no process state. Messages are ordered by
  `internalDate` then id, threads by thread id, so replaying the same records
  converges on the same rows (upserts on the source identity; people upsert on
  the email identity).

  ## Mapping

  | Canonical | From the `users.messages.get` payload |
  |---|---|
  | `Conversation.external_id` | `threadId` |
  | `Conversation.subject` | `Subject` header of the thread's earliest message that has one |
  | `Conversation.participants` | sorted `"emails"` from `From`/`To`/`Cc` across the thread, and their `"person_ids"` |
  | `Message.external_id` | `id` |
  | `Message.sent_at` | `internalDate` (epoch ms) |
  | `Message.direction` | `:outbound` when labelled `SENT`, else `:inbound` |
  | `Message.body` | the first `text/plain` part (format `full`), else `snippet` |
  | `Message.sender` | the `From` address's Person |
  | `Person.email` / `.name` | each address, with the display name when one was given |

  ## Usage

      Gmail.replay(owner: user, tenant: organization)
      Gmail.project(source_objects, owner: user, tenant: organization)

  `replay/1` reads every landed `gmail.messages` SourceObject; `project/2`
  takes landed records from elsewhere (for instance the scoped lander's
  decrypting reader). Both need `owner:` and `tenant:`: canonical rows are the
  account owner's, and this module does not guess whose.
  """

  alias AshEnterprise.Canonical.{Conversation, Message, Person}
  alias AshEnterprise.Ingestion.SourceObject

  @external_system "gmail"
  @stream "gmail.messages"
  @subject_max 998

  @type counts :: %{
          source_objects: non_neg_integer(),
          admitted: non_neg_integer(),
          denied: non_neg_integer(),
          conversations: non_neg_integer(),
          messages: non_neg_integer(),
          people: non_neg_integer()
        }

  @doc "Project every landed `gmail.messages` record."
  @spec replay(keyword()) :: {:ok, counts()}
  def replay(opts) do
    @external_system
    |> SourceObject.by_system!(authorize?: false)
    |> Enum.filter(&(stream_of(&1) == @stream))
    |> Enum.sort_by(& &1.external_id)
    |> project(opts)
  end

  @doc """
  Project the given landed records (maps or structs with `external_id`,
  `raw_payload` and `source_metadata`). Records on other streams are ignored.
  """
  @spec project([map()], keyword()) :: {:ok, counts()}
  def project(sources, opts) do
    context = context(opts)
    gate = zone_gate()
    sources = Enum.filter(sources, &(stream_of(&1) == @stream))

    {admitted, denied} = Enum.split_with(sources, &(gate.admit(&1, context) == :ok))

    threads =
      admitted
      |> Enum.map(&parse/1)
      |> Enum.group_by(& &1.thread_id)
      |> Enum.sort_by(fn {thread_id, _messages} -> thread_id end)

    people =
      Enum.reduce(threads, MapSet.new(), fn {thread_id, messages}, seen ->
        project_thread(thread_id, messages, context, seen)
      end)

    {:ok,
     %{
       source_objects: length(sources),
       admitted: length(admitted),
       denied: length(denied),
       conversations: length(threads),
       messages: length(admitted),
       people: MapSet.size(people)
     }}
  end

  # --- one thread --------------------------------------------------------------

  defp project_thread(thread_id, messages, context, people_seen) do
    messages = Enum.sort_by(messages, &{DateTime.to_unix(&1.sent_at, :microsecond), &1.id})

    # One Person per address; the first display name seen (in message order)
    # names them. `upsert_fields` leaves an existing name alone when this
    # payload carries none.
    people =
      messages
      |> Enum.flat_map(&[&1.from | &1.to ++ &1.cc])
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(%{}, fn %{email: email, name: name}, acc ->
        Map.update(acc, email, name, &(&1 || name))
      end)
      |> Map.new(fn {email, name} -> {email, upsert_person(email, name, context)} end)

    emails = people |> Map.keys() |> Enum.sort()
    person_ids = people |> Map.values() |> Enum.map(& &1.id) |> Enum.sort()

    conversation =
      Conversation.upsert_from_source!(
        %{
          external_system: @external_system,
          external_id: thread_id,
          subject: thread_subject(messages),
          participants: %{"emails" => emails, "person_ids" => person_ids}
        },
        tenant: context.tenant_id,
        authorize?: false
      )

    Enum.each(messages, &upsert_message(&1, conversation, people, context))

    Enum.into(person_ids, people_seen)
  end

  defp thread_subject(messages) do
    Enum.find_value(messages, fn message ->
      case message.subject do
        subject when is_binary(subject) and subject != "" ->
          String.slice(subject, 0, @subject_max)

        _ ->
          nil
      end
    end)
  end

  defp upsert_message(message, conversation, people, context) do
    sender = message.from && Map.get(people, message.from.email)

    Message
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      %{
        external_system: @external_system,
        external_id: message.id,
        body: message.body,
        sent_at: message.sent_at,
        direction: message.direction,
        conversation_id: conversation.id,
        sender_id: sender && sender.id
      },
      tenant: context.tenant_id,
      authorize?: false
    )
    # `upsert_from_source` does not accept the owner columns, and Message is
    # user-owned; the owner is the replay context's, INSERT-time only (owner
    # columns are not in the action's upsert_fields). Forced after
    # `for_create`, which refuses attributes the action does not accept.
    |> Ash.Changeset.force_change_attributes(owner_attributes(context))
    |> Ash.create!()
  end

  defp upsert_person(email, name, context) do
    Person
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(owner_attributes(context), %{email: email, name: name}),
      tenant: context.tenant_id,
      authorize?: false
    )
    # The full upsert option set must be repeated at call time; see the same
    # call in AshEnterprise.Canonical.Projection.
    |> Ash.create!(
      upsert?: true,
      upsert_identity: :unique_email,
      upsert_fields: if(name in [nil, ""], do: [], else: [:name])
    )
  end

  defp owner_attributes(context) do
    %{
      owner_id: context.owner_id,
      owner_type: :user,
      owning_user_id: context.owner_id,
      owning_business_unit_id: context.business_unit_id
    }
  end

  # --- payload reading ---------------------------------------------------------

  defp parse(source) do
    payload = source.raw_payload
    headers = headers(payload)

    %{
      id: source.external_id,
      thread_id: present(payload["threadId"]) || source.external_id,
      subject: headers["subject"],
      from: headers |> Map.get("from") |> addresses() |> List.first(),
      to: headers |> Map.get("to") |> addresses(),
      cc: headers |> Map.get("cc") |> addresses(),
      sent_at: sent_at(payload, source),
      direction: if("SENT" in List.wrap(payload["labelIds"]), do: :outbound, else: :inbound),
      body: plain_text(payload["payload"]) || present(payload["snippet"])
    }
  end

  # Header names are case-insensitive; the first occurrence wins.
  defp headers(payload) do
    payload
    |> get_in(["payload", "headers"])
    |> List.wrap()
    |> Enum.reduce(%{}, fn
      %{"name" => name, "value" => value}, acc when is_binary(name) and is_binary(value) ->
        Map.put_new(acc, String.downcase(name), value)

      _other, acc ->
        acc
    end)
  end

  defp sent_at(payload, source) do
    with ms when is_binary(ms) <- payload["internalDate"],
         {ms, ""} <- Integer.parse(ms),
         {:ok, datetime} <- DateTime.from_unix(ms * 1000, :microsecond) do
      datetime
    else
      _ ->
        # The id only: the payload is personal data and stays out of errors.
        raise ArgumentError,
              "gmail SourceObject #{inspect(source.external_id)} cannot be projected: " <>
                "internalDate is missing or not epoch milliseconds"
    end
  end

  # The first text/plain part, depth first (format `full`). Gmail bodies are
  # base64url; anything that does not decode to valid UTF-8 is not projected.
  defp plain_text(%{"mimeType" => "text/plain", "body" => %{"data" => data}})
       when is_binary(data) do
    case Base.url_decode64(String.trim_trailing(data, "="), padding: false) do
      {:ok, text} -> if String.valid?(text), do: present(text)
      :error -> nil
    end
  end

  defp plain_text(%{"parts" => parts}) when is_list(parts),
    do: Enum.find_value(parts, &plain_text/1)

  defp plain_text(_part), do: nil

  @doc false
  # An RFC 5322 address list, crudely: split on commas outside quotes and angle
  # brackets, then take `Name <addr>` or a bare `addr`. Anything without an @
  # is not an address and is not linked.
  def addresses(nil), do: []

  def addresses(header) when is_binary(header) do
    header
    |> split_list()
    |> Enum.map(&address/1)
    |> Enum.reject(&is_nil/1)
  end

  defp split_list(header) do
    {parts, current, _state} =
      header
      |> String.graphemes()
      |> Enum.reduce({[], [], %{quoted?: false, angle?: false}}, fn
        "\"", {parts, current, state} ->
          {parts, ["\"" | current], %{state | quoted?: not state.quoted?}}

        "<", {parts, current, %{quoted?: false} = state} ->
          {parts, ["<" | current], %{state | angle?: true}}

        ">", {parts, current, %{quoted?: false} = state} ->
          {parts, [">" | current], %{state | angle?: false}}

        ",", {parts, current, %{quoted?: false, angle?: false} = state} ->
          {[current | parts], [], state}

        char, {parts, current, state} ->
          {parts, [char | current], state}
      end)

    [current | parts]
    |> Enum.reverse()
    |> Enum.map(&(&1 |> Enum.reverse() |> Enum.join() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp address(part) do
    case Regex.run(~r/^(.*)<([^<>]+)>\s*$/s, part) do
      [_, name, email] -> email_and_name(email, name)
      nil -> email_and_name(part, nil)
    end
  end

  defp email_and_name(email, name) do
    email = email |> String.trim() |> String.downcase()

    if String.contains?(email, "@") and not String.contains?(email, " ") do
      %{email: email, name: display_name(name)}
    end
  end

  defp display_name(nil), do: nil

  defp display_name(name) do
    name |> String.trim() |> String.trim("\"") |> String.trim() |> present()
  end

  # --- config and context ------------------------------------------------------

  defp zone_gate do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:zone_gate, AshEnterprise.Canonical.Projections.Gmail.DenyAll)
  end

  defp context(opts) do
    owner = Keyword.fetch!(opts, :owner)
    tenant = Keyword.fetch!(opts, :tenant)

    %{
      owner_id: id_of(owner, :owner),
      tenant_id: id_of(tenant, :tenant),
      business_unit_id: Map.get(owner_struct(owner), :owning_business_unit_id)
    }
  end

  defp owner_struct(%{} = owner), do: owner
  defp owner_struct(_id), do: %{}

  defp id_of(%{id: id}, kind), do: id_of(id, kind)

  defp id_of(id, kind) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "gmail projection #{kind} is not a UUID: #{inspect(id)}"
    end
  end

  defp id_of(other, kind) do
    raise ArgumentError,
          "gmail projection #{kind} must be a record or UUID, got: #{inspect(other)}"
  end

  defp stream_of(%{source_metadata: %{"stream" => stream}}), do: stream
  defp stream_of(_source), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
