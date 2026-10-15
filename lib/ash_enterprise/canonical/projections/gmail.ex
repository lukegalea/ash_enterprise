defmodule AshEnterprise.Canonical.Projections.Gmail do
  @moduledoc """
  Raw → canonical projection for Gmail (epic E4, ADR 0037's host-declared
  pattern): landed `gmail.messages` records become
  `AshEnterprise.Canonical.Conversation` (one per Gmail thread),
  `AshEnterprise.Canonical.Message` (one per message) and
  `AshEnterprise.Canonical.Person` (one per email address: v1 linkage is the
  address and nothing else, no fuzzy resolution).

  ## Only the owner's own mailboxes

  A landed record is projected for `owner:` only when its
  `source_metadata["linked_account_id"]` names one of that owner's
  `google-mail` linked accounts in `tenant:` (`LinkedAccount.owned_by`). Every
  other record (another user's mailbox, another tenant's, an unlinked
  account's, or one with no account at all) is counted as `foreign` and never
  reaches the zone gate, let alone the canonical model. SourceObject is
  untenanted and unowned, so this is the only thing that ties a raw row to the
  person it is projected for.

  ## Gated by zone admission, deny by default (ADR 0042)

  Every landed record is put to the configured
  `AshEnterprise.Canonical.Projections.ZoneGate` before anything is derived
  from it. The default gate admits nothing, so out of the box this module
  reads, refuses and writes **no** canonical row. A deployment that declares
  the canonical store's zone points `:zone_gate` at
  `AshEnterprise.Canonical.Projections.ZoneAdmission`, which admits a record
  on its linked account's tags. A refused record is counted by reason
  (`denied_by`), never projected and never partially projected.

  ## Erasure (ADR 0024)

  Every canonical row carries the `erasure_scope_id` of the landed record it
  was projected from — one scope per linked account — so the message body
  (and the conversation's sealed columns) are under the same key as the raw
  landing, and one shred reaches all of them. Records are read back through
  `SourceObject`'s decrypting path; a record whose scope has been shredded
  reads as `AshEnterprise.Erasure.Shredded`, is counted as `shredded` and
  projects nothing. A record with no scope at all (a bare map that was never
  landed) is counted as `unscoped` and never projected.

  ## One bad record does not stop a replay

  Each thread is written in one transaction. A write that fails (or a payload
  with no message id or `internalDate`, also counted as `unparseable`) is
  counted as `failed` and the replay carries on; the failure is reduced to the resource and field names
  (`AshEnterprise.Canonical.Projections.Write`), because an Ash error quotes
  the value it rejected, and the value is mailbox content. Display names are
  clipped to `Person.name`'s 256 characters and over-long addresses are not
  linked, so a sender cannot make the write fail in the first place.

  ## Deterministic

  Everything projected is a function of the admitted payloads and the replay
  context: no wall clock, no process state. Messages are ordered by
  `internalDate` then id, threads by thread id, so replaying the same records
  converges on the same rows (upserts on the source identity; people upsert on
  the email identity).

  ## Mapping

  Gmail ids are unique within one mailbox only, so every projected identity is
  namespaced by the linked account it came through
  (`AshEnterprise.Integration.Gmail.Sync.external_id/2`,
  `"<linked_account_id>:<gmail id>"`).

  | Canonical | From the `users.messages.get` payload |
  |---|---|
  | `Conversation.external_id` | `<linked_account_id>:<threadId>` |
  | `Conversation.subject` | the thread's first message's `Subject` header |
  | `Conversation.participants` | every address in the thread, and the owner's people among them |
  | `Message.external_id` | `<linked_account_id>:<id>` |
  | `Message.sent_at` | `internalDate` (epoch ms) |
  | `Message.direction` | `:outbound` when labelled `SENT`, else `:inbound` |
  | `Message.body` | the first `text/plain` part (format `full`), else `snippet` |
  | `Message.sender` | the `From` address's Person, when that Person is the owner's |
  | `Person.email` / `.name` | each address, with the display name when one was given |

  ## Whose rows these are

  `Conversation`, `Message` and `Person` are user-owned and owner-only
  (`AshEnterprise.Security.Privilege.owner_only?/1`): the replay owner reads
  them, and no role grants another user more than their own. The thread's
  subject and participants are sealed under the scope like the bodies.

  `Person` is user-owned but unique on email per tenant, and its owner is set
  at insert only. A Person another user already owns is neither renamed from
  this mailbox's headers (its owner is checked before the upsert) nor linked
  from this owner's messages (`sender_id` stays nil).

  ## Usage

      Gmail.replay(owner: user, tenant: organization)
      Gmail.project(source_objects, owner: user, tenant: organization)

  `replay/1` reads the landed `gmail.messages` SourceObjects; `project/2`
  takes landed records from elsewhere (for instance the scoped lander's
  decrypting reader). A sync step projects what it landed itself
  (`AshEnterprise.Canonical.Projections.Pending`, through `with_threads/2` and
  `project/2`'s `only:`). Both need `owner:` and `tenant:`, and both project only
  the records of the owner's own linked accounts in that tenant.
  """

  alias AshEnterprise.Canonical.{Conversation, Message, Person}
  alias AshEnterprise.Canonical.Projections.{Write, ZoneGate}
  alias AshEnterprise.Erasure.{LiveScope, Shredded}
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.Gmail.Sync
  alias AshEnterprise.Integration.LinkedAccount

  require Ash.Query

  @integration "google-mail"

  @external_system "gmail"
  @stream "gmail.messages"

  # `Person.name` / `Person.email` limits.
  @name_max 256
  @email_max 320

  @type counts :: %{
          source_objects: non_neg_integer(),
          foreign: non_neg_integer(),
          shredded: non_neg_integer(),
          unscoped: non_neg_integer(),
          admitted: non_neg_integer(),
          denied: non_neg_integer(),
          denied_by: %{atom() => pos_integer()},
          failed: non_neg_integer(),
          unparseable: non_neg_integer(),
          conversations: non_neg_integer(),
          messages: non_neg_integer(),
          people: non_neg_integer()
        }

  @doc "Project the owner's landed `gmail.messages` records."
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
  `raw_payload` and `source_metadata`). Records on other streams are ignored;
  records not from one of the owner's linked accounts in the tenant are
  counted as `foreign` and not projected.

  ## `only:` — the incremental form

  `only:` (a set of `external_id`s) is how a sync step projects just what it
  landed (`AshEnterprise.Canonical.Projections.Pending`). A Gmail thread is
  projected whole — its conversation's subject and participants are derived
  from every message in it — so the step passes the new records *and* the rest
  of their threads, and names the new ones in `only:`. Then:

    * only threads holding at least one admitted `only:` record are written
      (whole, from every admitted record passed in);
    * every count is about the `only:` records alone — `messages` is how many
      of them were written, `denied_by` how many of them the gate refused —
      except `conversations` and `people`, which count the rows written;
    * records outside `only:` are put to the zone gate like any other (a
      refused one is never written), but their refusals are not counted.

  Without `only:` every record passed in is both written and counted.
  """
  @spec project([map()], keyword()) :: {:ok, counts()}
  def project(sources, opts) do
    context = context(opts)
    gate = ZoneGate.configured(__MODULE__)
    counted? = counted_fun(Keyword.get(opts, :only))
    sources = Enum.filter(sources, &(stream_of(&1) == @stream))
    linked_accounts = owned_accounts(context)
    accounts = linked_accounts |> Map.keys() |> MapSet.new()
    context = Map.put(context, :linked_accounts, linked_accounts)

    {owned, foreign} = Enum.split_with(sources, &MapSet.member?(accounts, account_of(&1)))
    {shredded, readable} = Enum.split_with(owned, &Shredded.shredded?(&1.raw_payload))
    {scoped, unscoped} = Enum.split_with(readable, &is_binary(Map.get(&1, :erasure_scope_id)))
    {counted_scoped, context_scoped} = Enum.split_with(scoped, counted?)
    {admitted, denied_by} = ZoneGate.partition(gate, counted_scoped, context)
    {admitted_context, _not_counted} = ZoneGate.partition(gate, context_scoped, context)
    ZoneGate.log_refusals(:gmail, denied_by)

    {parsed, unparseable} =
      (admitted ++ admitted_context)
      |> Enum.map(&parse(&1, counted?))
      |> Enum.split_with(&match?({:ok, _}, &1))

    unparseable = Enum.count(unparseable, &match?({:error, :unparseable, true}, &1))

    threads =
      parsed
      |> Enum.map(fn {:ok, message} -> message end)
      |> Enum.group_by(& &1.thread_id)
      |> Enum.filter(fn {_thread_id, messages} -> Enum.any?(messages, & &1.counted?) end)
      |> Enum.sort_by(fn {thread_id, _messages} -> thread_id end)

    initial = %{
      people: MapSet.new(),
      conversations: 0,
      messages: 0,
      shredded: Enum.count(shredded, counted?),
      failed: unparseable
    }

    totals =
      Enum.reduce(threads, initial, fn {thread_id, messages}, acc ->
        new = Enum.count(messages, & &1.counted?)

        case project_thread(thread_id, messages, context) do
          {:ok, {:projected, person_ids}} ->
            %{
              acc
              | people: Enum.into(person_ids, acc.people),
                conversations: acc.conversations + 1,
                messages: acc.messages + new
            }

          {:ok, :shredded} ->
            %{acc | shredded: acc.shredded + new}

          # Structural only (`Projections.Write`): the thread is rolled back
          # whole, counted, and the replay carries on.
          {:error, _reason} ->
            %{acc | failed: acc.failed + new}
        end
      end)

    {:ok,
     %{
       source_objects: Enum.count(sources, counted?),
       foreign: Enum.count(foreign, counted?),
       shredded: totals.shredded,
       unscoped: Enum.count(unscoped, counted?),
       admitted: length(admitted),
       denied: denied_by |> Map.values() |> Enum.sum(),
       denied_by: denied_by,
       failed: totals.failed,
       unparseable: unparseable,
       conversations: totals.conversations,
       messages: totals.messages,
       people: MapSet.size(totals.people)
     }}
  end

  @doc """
  `delta` (records newly landed through `linked_account_id`) with the rest of
  the threads they belong to — what an incremental projection passes to
  `project/2` alongside `only:`. The thread is read from the bookkeeping the
  sync lands with each message (`source_metadata["thread_id"]`), so finding
  it decrypts nothing but the thread itself.
  """
  @spec with_threads([map()], Ash.UUID.t()) :: [map()]
  def with_threads(delta, linked_account_id) do
    thread_ids =
      for record <- delta,
          thread_id = get_in(record.source_metadata, ["thread_id"]),
          is_binary(thread_id),
          uniq: true,
          do: thread_id

    threads =
      if thread_ids == [] do
        []
      else
        SourceObject
        |> Ash.Query.filter(external_system == ^@external_system)
        |> Ash.Query.filter(source_metadata["linked_account_id"] == ^linked_account_id)
        |> Ash.Query.filter(source_metadata["stream"] == ^@stream)
        |> Ash.Query.filter(source_metadata["thread_id"] in ^thread_ids)
        |> Ash.Query.sort(:external_id)
        |> Ash.read!(authorize?: false)
      end

    Enum.uniq_by(delta ++ threads, & &1.external_id)
  end

  defp counted_fun(nil), do: fn _source -> true end
  defp counted_fun(%MapSet{} = only), do: &MapSet.member?(only, &1.external_id)
  defp counted_fun(only) when is_list(only), do: counted_fun(MapSet.new(only))

  # --- one thread --------------------------------------------------------------

  # One transaction per thread, opened with the thread's scope locked and
  # checked live (`AshEnterprise.Erasure.LiveScope`): the people are not
  # sealed, so a shred that committed after the landing must stop them being
  # written at all, not only the sealed message bodies. The thread id is
  # namespaced by the linked account, so all of its messages share one scope.
  defp project_thread(thread_id, messages, context) do
    messages = Enum.sort_by(messages, &{DateTime.to_unix(&1.sent_at, :microsecond), &1.id})
    scope_id = hd(messages).erasure_scope_id

    LiveScope.run([scope_id], fn live ->
      if MapSet.member?(live, scope_id),
        do: write_thread(thread_id, messages, scope_id, context),
        else: {:ok, :shredded}
    end)
  end

  defp write_thread(thread_id, messages, scope_id, context) do
    with {:ok, people} <- upsert_people(messages, context),
         {:ok, conversation} <- write_conversation(thread_id, messages, people, scope_id, context),
         :ok <- upsert_messages(messages, conversation, people, context) do
      {:ok, {:projected, people |> Map.values() |> Enum.map(& &1.id)}}
    end
  end

  # One Person per address; the first display name seen (in message order)
  # names them. `upsert_fields` leaves an existing name alone when this
  # payload carries none. Addresses whose Person another user owns are not
  # linked (`upsert_person/3` returns nil for them).
  defp upsert_people(messages, context) do
    messages
    |> Enum.flat_map(&[&1.from | &1.to ++ &1.cc])
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn %{email: email, name: name}, acc ->
      Map.update(acc, email, name, &(&1 || name))
    end)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {email, name}, {:ok, people} ->
      case upsert_person(email, name, context) do
        {:ok, nil} -> {:cont, {:ok, people}}
        {:ok, person} -> {:cont, {:ok, Map.put(people, email, person)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # The owner's, sealed under the thread's scope: the first message's subject,
  # and every address in the thread with the owner's people among them.
  defp write_conversation(thread_id, messages, people, scope_id, context) do
    emails =
      messages
      |> Enum.flat_map(&[&1.from | &1.to ++ &1.cc])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.email)
      |> Enum.uniq()
      |> Enum.sort()

    Conversation
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      %{
        external_system: @external_system,
        external_id: thread_id,
        subject: hd(messages).subject,
        participants: %{
          "emails" => emails,
          "person_ids" => people |> Map.values() |> Enum.map(& &1.id) |> Enum.sort()
        },
        erasure_scope_id: scope_id
      }
      |> Map.merge(owner_attributes(context)),
      tenant: context.tenant_id,
      authorize?: false
    )
    |> Write.create()
  end

  defp upsert_messages(messages, conversation, people, context) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case upsert_message(message, conversation, people, context) do
        {:ok, _message} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
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
        sender_id: sender && sender.id,
        # The body is sealed under the same key as the raw landing (ADR 0024).
        erasure_scope_id: message.erasure_scope_id
      }
      # The owner is the replay context's, INSERT-time only (owner columns are
      # not in the action's upsert_fields).
      |> Map.merge(owner_attributes(context)),
      tenant: context.tenant_id,
      authorize?: false
    )
    |> Write.create()
  end

  # The owner's Person for `email`, or nil when the address already belongs to
  # a Person another user owns: `unique_email` is per tenant, not per owner,
  # so that row is theirs and this mailbox neither renames nor links it.
  #
  # Checked by a read before the upsert rather than with an `upsert_condition`:
  # the audit wrapper (AshEvents) does not handle a skipped upsert. Residual:
  # two owners' replays inserting the same new address at the same instant can
  # still let the second rename the first's row; it is still not linked, since
  # the owner check below runs on the row the upsert returns.
  defp upsert_person(email, name, context) do
    owner_id = context.owner_id

    case existing_person(email, context) do
      {:ok, %Person{owner_id: other}} when other != owner_id ->
        {:ok, nil}

      {:ok, _own_or_none} ->
        case write_person(email, name, context) do
          {:ok, %Person{owner_id: ^owner_id} = person} -> {:ok, person}
          {:ok, _theirs} -> {:ok, nil}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp existing_person(email, context) do
    case Person.read(
           query: [filter: [email: email], limit: 1],
           tenant: context.tenant_id,
           authorize?: false
         ) do
      {:ok, people} -> {:ok, List.first(people)}
      {:error, error} -> {:error, Write.failure(Person, error)}
    end
  end

  defp write_person(email, name, context) do
    Person
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(owner_attributes(context), %{email: email, name: name}),
      tenant: context.tenant_id,
      authorize?: false
    )
    # The full upsert option set must be repeated at call time; see the same
    # call in AshEnterprise.Canonical.Projection.
    |> Write.create(
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

  # `{:ok, message}`, or `{:error, :unparseable, counted?}` for a payload
  # with no message id or no usable `internalDate`: counted as failed, never
  # guessed.
  defp parse(source, counted?) do
    payload = source.raw_payload

    with {:ok, gmail_id} <- gmail_id(payload),
         {:ok, sent_at} <- sent_at(payload) do
      {:ok, parsed(source, payload, gmail_id, sent_at, counted?.(source))}
    else
      {:error, :unparseable} -> {:error, :unparseable, counted?.(source)}
    end
  end

  defp parsed(source, payload, gmail_id, sent_at, counted?) do
    headers = headers(payload)
    account = account_of(source)

    %{
      id: Sync.external_id(account, gmail_id),
      counted?: counted?,
      erasure_scope_id: source.erasure_scope_id,
      thread_id: Sync.external_id(account, present(payload["threadId"]) || gmail_id),
      subject: headers |> Map.get("subject") |> present(),
      from: headers |> Map.get("from") |> addresses() |> List.first(),
      to: headers |> Map.get("to") |> addresses(),
      cc: headers |> Map.get("cc") |> addresses(),
      sent_at: sent_at,
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

  defp gmail_id(payload) do
    case present(payload["id"]) do
      nil -> {:error, :unparseable}
      id -> {:ok, id}
    end
  end

  defp sent_at(payload) do
    with ms when is_binary(ms) <- payload["internalDate"],
         {ms, ""} <- Integer.parse(ms),
         {:ok, datetime} <- DateTime.from_unix(ms * 1000, :microsecond) do
      {:ok, datetime}
    else
      _ -> {:error, :unparseable}
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

  # Longer than any deliverable address (RFC 5321) and than `Person.email`
  # accepts: not an address worth linking (as the calendar projector).
  defp email_and_name(email, name) do
    email = email |> String.trim() |> String.downcase()

    if String.contains?(email, "@") and not String.contains?(email, " ") and
         byte_size(email) <= @email_max do
      %{email: email, name: display_name(name)}
    end
  end

  defp display_name(nil), do: nil

  # Any sender sets their display name, so it is clipped to what `Person.name`
  # holds rather than allowed to fail the write.
  defp display_name(name) do
    name
    |> String.trim()
    |> String.trim("\"")
    |> String.trim()
    |> String.slice(0, @name_max)
    |> present()
  end

  # --- config and context ------------------------------------------------------

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

  defp account_of(%{source_metadata: %{"linked_account_id" => id}}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp account_of(_source), do: nil

  # The owner's google-mail linked accounts in the replay tenant, whatever
  # their lifecycle (a paused sync's mail is still the owner's).
  defp owned_accounts(context) do
    context.owner_id
    |> LinkedAccount.owned_by!(@integration, tenant: context.tenant_id, authorize?: false)
    |> Map.new(&{&1.id, &1})
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
