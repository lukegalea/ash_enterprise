defmodule AshEnterprise.Canonical.Projections.Slack do
  @moduledoc """
  Raw Slack landings → canonical `Conversation`, `Message` and `Person` rows
  (epic E4, Slack vertical; ADR 0037's host-declared projection pattern).

  Input is what the Slack sync landed for **one linked account**
  (`AshEnterprise.Integration.Slack.Records`): the `slack.conversations`,
  `slack.messages` and `slack.users` streams. Output:

    * one `Conversation` per **public channel** — `external_id` is the
      conversation record's id, `subject` `"#name"`; `participants` the Slack
      user ids that appear in it, plus the emails and person ids resolved for
      them;
    * one `Message` per projected message in a public channel — body is
      Slack's `text`, `sent_at` its `ts`, `direction` `:outbound` when the
      author is the account's own Slack user, `:inbound` otherwise;
      join/leave/topic notices are landed raw but not projected;
    * one `Person` per member whose profile carries an email (the v1 linkage
      key, exactly as the calendar projector: no email, no person — a
      name-only row would be re-minted on every replay).

  Deterministic: every row is a function of the landed payloads and the linked
  account (whose owner and tenant the rows are written under), never of a
  clock or the order rows were read in. Replaying twice converges on the same
  rows.

  ## Zone admission — DENY by default (ADR 0042)

  Slack content is personal and confidential data. Every landed record is put
  to the configured `AshEnterprise.Canonical.Projections.ZoneGate` before
  anything is derived from it, and only admitted records are projected:

      config :ash_enterprise, AshEnterprise.Canonical.Projections.Slack,
        zone_gate: AshEnterprise.Canonical.Projections.ZoneAdmission

  The default gate admits nothing. `ZoneAdmission` admits a record on its
  linked account's tags (`data_class`, `residency`, set by the operator)
  against the canonical store's declared zone, so an untagged account, an
  undeclared zone or tags the zone cannot hold project nothing. Refusals are
  counted by reason (`denied`, `denied_by`) and logged as counts.

  ## Only public channels, for now

  `Conversation`, `Message` and `Person` are user-owned and owner-only
  (`AshEnterprise.Security.Privilege.owner_only?/1`), so nothing projected
  here is readable by another user. IMs, MPIMs and private channels are still
  **not projected** — neither the conversation nor its messages: whether one
  user's direct messages belong in the canonical model at all is a separate
  decision from whether they are admissible. A conversation is public only
  when its landed `conversations.list` record says so (`is_channel`,
  `is_private: false`, not an IM or MPIM); messages of a conversation with no
  landed record are not projected either, because nothing says it is public.
  They stay landed raw, under the account's shred scope.

  ## The account's own Slack user

  `direction` needs the account's own Slack user id. Pass `self_user_id:`;
  otherwise it is inferred from IMs (in a DM, the author who is not the
  conversation's `user` is the account holder) when that yields exactly one
  id, and every message is `:inbound` when it does not.

  ## Erasure (ADR 0024)

  Every `Conversation` and `Message` is written with the `erasure_scope_id` of
  the landed record it was projected from (the linked account's scope), so its
  sealed content — subject, participants, body — is under the same key as the
  raw landing and one shred reaches all of it. Pass landed `SourceObject` rows
  (`replay/3` reads them through the decrypting path), or `SourceRecord`s with
  `erasure_scope_id:` in the options. A record whose scope has been shredded
  reads as `AshEnterprise.Erasure.Shredded` and projects nothing; a record
  with no scope is never projected. `Person` rows are not sealed (their name
  and email are `sensitive?`, so the audit log records them as `nil`), so
  each is written only while its member record's scope is live, checked under
  a lock a shred waits for (`AshEnterprise.Erasure.LiveScope`).

  ## People another user owns

  `Person` is unique on email per tenant and owned by whoever projected it
  first. A member whose Person another user already owns (from their Gmail,
  Calendar or Slack) is neither renamed from this account's Slack profile nor
  linked from its messages (`sender_id` nil) or conversations
  (`participants.person_ids`) — the Gmail and Calendar rule — so a shred of
  this account leaves nothing it wrote in someone else's rows.

  ## One bad record does not stop a replay

  Every write is non-raising (`AshEnterprise.Canonical.Projections.Write`): a
  failure is counted in `failed`, reduced to resource and field names (an Ash
  error quotes the value it rejected, and the value is Slack content), and the
  replay carries on. Display names are clipped to `Person.name`'s 256
  characters and over-long addresses are not linked, so a member's profile
  cannot make the write fail in the first place.
  """

  alias AshEnterprise.Canonical.{Conversation, Message, Person}
  alias AshEnterprise.Canonical.Projections.{Write, ZoneGate}
  alias AshEnterprise.Erasure.{LiveScope, Shredded}
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Integration.Slack.Records
  alias AshEnterprise.Security.ActorContext

  require Ash.Query

  # Notices about the conversation rather than messages in it: landed raw,
  # not projected.
  @projected_subtypes [nil, "thread_broadcast", "file_share", "bot_message", "me_message"]

  # Where a message's erasure scope rides alongside its payload inside this
  # module. Not a Slack key; never written anywhere.
  @scope_key "__erasure_scope_id__"

  # `Person.name` / `Person.email` limits.
  @name_max 256
  @email_max 320

  @type counts :: %{
          admitted: non_neg_integer(),
          denied: non_neg_integer(),
          denied_by: %{atom() => pos_integer()},
          conversations: non_neg_integer(),
          messages: non_neg_integer(),
          people: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc """
  Replay everything landed for one of the actor's own Slack linked accounts
  (or their only one, when `linked_account_id` is nil).
  """
  @spec replay(struct(), Ash.UUID.t() | nil, keyword()) ::
          {:ok, counts()} | {:error, term()}
  def replay(actor, linked_account_id \\ nil, opts \\ []) do
    with {:ok, account} <- own_account(actor, linked_account_id) do
      sources =
        SourceObject
        |> Ash.Query.filter(external_system == ^Records.external_system())
        |> Ash.Query.filter(source_metadata["linked_account_id"] == ^account.id)
        |> Ash.Query.sort(:external_id)
        |> Ash.read!(authorize?: false)

      project(sources, account, opts)
    end
  end

  @doc """
  Project landed Slack records (`SourceRecord`s or `SourceObject` rows — both
  carry `external_id`, `raw_payload` and `source_metadata`) fetched through
  `linked_account`. Records of another linked account are ignored, as are
  records whose scope is shredded or unknown (see "Erasure"); the rest are
  projected only if the zone gate admits them.

  Options: `:self_user_id`, `:erasure_scope_id` (the scope `SourceRecord`s,
  which carry none of their own, were landed under).
  """
  @spec project([map()], struct(), keyword()) :: {:ok, counts()}
  def project(records, %LinkedAccount{} = account, opts \\ []) do
    context = context(account)

    {admitted, denied_by} =
      ZoneGate.partition(
        ZoneGate.configured(__MODULE__),
        Enum.filter(records, &(get_in(&1.source_metadata, ["linked_account_id"]) == account.id)),
        context
      )

    ZoneGate.log_refusals(:slack, denied_by)

    {:ok,
     admitted
     |> project_admitted(context, Keyword.get(opts, :erasure_scope_id), opts)
     |> Map.merge(%{
       admitted: length(admitted),
       denied: denied_by |> Map.values() |> Enum.sum(),
       denied_by: denied_by
     })}
  end

  defp project_admitted(records, context, default_scope, opts) do
    streams =
      records
      |> Enum.reject(&Shredded.shredded?(&1.raw_payload))
      |> Enum.map(&{&1, Map.get(&1, :erasure_scope_id) || default_scope})
      |> Enum.filter(fn {_record, scope_id} -> is_binary(scope_id) end)
      |> Enum.sort_by(fn {record, _scope_id} -> record.external_id end)
      |> Enum.group_by(fn {record, _scope_id} -> get_in(record.source_metadata, ["stream"]) end)

    conversations =
      streams
      |> Map.get(Records.stream(:conversations), [])
      |> Map.new(fn {record, _scope_id} -> {record.raw_payload["id"], record.raw_payload} end)

    conversation_scopes =
      streams
      |> Map.get(Records.stream(:conversations), [])
      |> Map.new(fn {record, scope_id} -> {record.raw_payload["id"], scope_id} end)

    messages =
      streams
      |> Map.get(Records.stream(:messages), [])
      |> Enum.map(fn {record, scope_id} ->
        {get_in(record.source_metadata, ["channel_id"]),
         Map.put(record.raw_payload, @scope_key, scope_id)}
      end)
      |> Enum.filter(fn {channel, message} ->
        is_binary(channel) and Records.ts?(message["ts"])
      end)

    user_records = Map.get(streams, Records.stream(:users), [])

    users =
      Map.new(user_records, fn {record, _scope_id} ->
        {record.raw_payload["id"], record.raw_payload}
      end)

    self_user_id =
      Keyword.get_lazy(opts, :self_user_id, fn -> infer_self(conversations, messages) end)

    {people, people_failed} = project_people(user_records, context)

    public =
      Map.filter(conversations, fn {_id, conversation} -> public_channel?(conversation) end)

    public_messages =
      Enum.filter(messages, fn {channel, _} -> Map.has_key?(public, channel) end)

    {conversation_rows, conversations_failed} =
      project_conversations(
        public,
        conversation_scopes,
        public_messages,
        users,
        people,
        context
      )

    {projected, messages_failed} =
      public_messages
      |> Enum.filter(fn {_channel, message} -> message["subtype"] in @projected_subtypes end)
      |> Enum.map(&project_message(&1, conversation_rows, people, self_user_id, context))
      |> Enum.split_with(&match?({:ok, _}, &1))

    %{
      conversations: map_size(conversation_rows),
      messages: length(projected),
      people: map_size(people),
      failed: people_failed + conversations_failed + length(messages_failed)
    }
  end

  # --- people ---------------------------------------------------------------------

  # One Person per member with an email, written only while the member
  # record's scope is live (checked under a lock a shred waits for,
  # `AshEnterprise.Erasure.LiveScope`): people are not sealed, so a shred
  # that committed after the landing must stop them being written at all.
  # Returns the people by Slack user id, and how many writes failed.
  defp project_people(user_records, context) do
    user_records
    |> Enum.sort_by(fn {record, _scope_id} -> to_string(record.raw_payload["id"]) end)
    |> Enum.reduce({%{}, 0}, fn {record, scope_id}, {people, failed} ->
      user = record.raw_payload

      with email when is_binary(email) <- email(user),
           {:ok, %Person{} = person} <- live_person(email, display_name(user), scope_id, context) do
        {Map.put(people, user["id"], person), failed}
      else
        {:error, _structural} -> {people, failed + 1}
        _no_email_shredded_or_theirs -> {people, failed}
      end
    end)
  end

  defp live_person(email, name, scope_id, context) do
    LiveScope.run([scope_id], fn live ->
      if MapSet.member?(live, scope_id), do: upsert_person(email, name, context), else: {:ok, nil}
    end)
  end

  # The owner's Person for `email`, or nil when another user in the tenant
  # already owns it (`unique_email` is per tenant, not per owner). That row is
  # theirs: this account neither renames it from a Slack profile nor links its
  # messages or conversations to it — the Gmail and Calendar rule. Checked by
  # a read before the upsert (the audit wrapper does not handle a skipped
  # upsert), and again on the row the upsert returns.
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
    Person
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(tenant: context.tenant_id, authorize?: false)
    |> case do
      {:ok, person} -> {:ok, person}
      {:error, error} -> {:error, Write.failure(Person, error)}
    end
  end

  defp write_person(email, name, context) do
    Person
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      %{
        email: email,
        name: name,
        owner_id: context.owner_id,
        owner_type: :user,
        owning_user_id: context.owner_id,
        owning_business_unit_id: context.business_unit_id
      },
      tenant: context.tenant_id,
      authorize?: false
    )
    # The full upsert option set, repeated at call time — see the calendar
    # projector in AshEnterprise.Canonical.Projection for why a partial set
    # silently becomes an insert.
    |> Write.create(
      upsert?: true,
      upsert_identity: :unique_email,
      upsert_fields: if(name in [nil, ""], do: [], else: [:name])
    )
  end

  # Longer than any deliverable address (RFC 5321) and than `Person.email`
  # accepts: not linked, as in the calendar and Gmail projectors.
  defp email(%{"profile" => %{"email" => email}}) when is_binary(email) do
    case String.trim(email) do
      "" -> nil
      trimmed when byte_size(trimmed) > @email_max -> nil
      trimmed -> trimmed
    end
  end

  defp email(_), do: nil

  defp display_name(user) do
    [
      get_in(user, ["profile", "real_name"]),
      user["real_name"],
      get_in(user, ["profile", "display_name"]),
      user["name"]
    ]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> clip_name()
  end

  # Any member sets their own profile name: clipped to what `Person.name`
  # holds rather than allowed to fail the write.
  defp clip_name(nil), do: nil
  defp clip_name(name), do: name |> String.trim() |> String.slice(0, @name_max)

  # --- conversations ------------------------------------------------------------------

  @doc false
  # Public in the workspace, per the conversation's own landed record. Anything
  # else — IM, MPIM, private channel, or a record that does not say — is not.
  def public_channel?(%{"is_channel" => true, "is_private" => false} = conversation),
    do: conversation["is_im"] != true and conversation["is_mpim"] != true

  def public_channel?(_conversation), do: false

  defp project_conversations(conversations, scopes, messages, users, people, context) do
    authors_by_channel =
      Enum.group_by(messages, &elem(&1, 0), fn {_channel, message} -> message["user"] end)

    channels = conversations |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.sort()

    channels
    |> Enum.map(fn channel ->
      conversation = Map.fetch!(conversations, channel)

      user_ids =
        [conversation["user"] | Map.get(authors_by_channel, channel, [])]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()
        |> Enum.sort()

      participants = %{
        "slack_user_ids" => user_ids,
        "emails" =>
          user_ids |> Enum.flat_map(&List.wrap(email(Map.get(users, &1, %{})))) |> Enum.sort(),
        "person_ids" => user_ids |> Enum.flat_map(&person_id(people, &1)) |> Enum.sort()
      }

      Conversation
      |> Ash.Changeset.for_create(
        :upsert_from_source,
        %{
          external_system: Records.external_system(),
          external_id: Records.conversation_id(context.linked_account_id, channel),
          subject: subject(conversation),
          participants: participants,
          erasure_scope_id: Map.fetch!(scopes, channel),
          # INSERT-time only, as on messages: owner columns are not upsert fields.
          owner_id: context.owner_id,
          owner_type: :user,
          owning_user_id: context.owner_id,
          owning_business_unit_id: context.business_unit_id
        },
        tenant: context.tenant_id,
        authorize?: false
      )
      |> Write.create()
      |> then(&{channel, &1})
    end)
    |> Enum.reduce({%{}, 0}, fn
      {channel, {:ok, row}}, {rows, failed} -> {Map.put(rows, channel, row), failed}
      {_channel, {:error, _structural}}, {rows, failed} -> {rows, failed + 1}
    end)
  end

  defp subject(%{"name" => name}) when is_binary(name) and name != "", do: "#" <> name
  defp subject(_conversation), do: nil

  # --- messages ------------------------------------------------------------------------

  # A message of a conversation whose write failed has nothing to belong to:
  # counted as failed with it.
  defp project_message({channel, message}, conversations, people, self_user_id, context) do
    case Map.fetch(conversations, channel) do
      {:ok, conversation} ->
        write_message(channel, message, conversation, people, self_user_id, context)

      :error ->
        {:error, :conversation_not_projected}
    end
  end

  defp write_message(channel, message, conversation, people, self_user_id, context) do
    author = message["user"]

    Message
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      %{
        external_system: Records.external_system(),
        external_id: Records.message_id(context.linked_account_id, channel, message["ts"]),
        body: message["text"],
        sent_at: Records.ts_to_datetime(message["ts"]),
        direction:
          if(is_binary(author) and author == self_user_id, do: :outbound, else: :inbound),
        conversation_id: conversation.id,
        sender_id: people |> person_id(author) |> List.first(),
        # Sealed under the same key as the raw landing it came from.
        erasure_scope_id: Map.fetch!(message, @scope_key),
        # On a conflict the owner is not in `upsert_fields`, so the first
        # projection wins, as everywhere else in this domain.
        owner_id: context.owner_id,
        owner_type: :user,
        owning_user_id: context.owner_id,
        owning_business_unit_id: context.business_unit_id
      },
      tenant: context.tenant_id,
      authorize?: false
    )
    |> Write.create()
  end

  defp person_id(people, user_id) do
    case Map.get(people, user_id) do
      %{id: id} -> [id]
      nil -> []
    end
  end

  # In an IM the conversation's `user` is the counterpart, so any other author
  # is the account holder. Only an unambiguous answer counts.
  defp infer_self(conversations, messages) do
    counterparts =
      conversations
      |> Map.values()
      |> Enum.filter(&(&1["is_im"] == true))
      |> Map.new(&{&1["id"], &1["user"]})

    messages
    |> Enum.flat_map(fn {channel, message} ->
      author = message["user"]

      case Map.fetch(counterparts, channel) do
        {:ok, counterpart} when is_binary(author) and author != counterpart -> [author]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> case do
      [self] -> self
      _ -> nil
    end
  end

  # --- context -------------------------------------------------------------------------

  defp own_account(actor, linked_account_id) do
    case ActorContext.tenant(actor) do
      nil ->
        {:error, :no_linked_account}

      tenant ->
        case LinkedAccount.mine("slack", actor: actor, tenant: tenant) do
          {:ok, accounts} -> pick(accounts, linked_account_id)
          {:error, error} -> {:error, error}
        end
    end
  end

  defp pick([account], nil), do: {:ok, account}
  defp pick([], nil), do: {:error, :no_linked_account}
  defp pick([_ | _], nil), do: {:error, :ambiguous_linked_account}

  defp pick(accounts, id) do
    case Enum.find(accounts, &(&1.id == id)) do
      nil -> {:error, :no_linked_account}
      account -> {:ok, account}
    end
  end

  defp context(account) do
    %{
      linked_accounts: %{account.id => account},
      linked_account_id: account.id,
      owner_id: account.owner_id,
      business_unit_id: account.owning_business_unit_id,
      tenant_id: account.organization_id
    }
  end
end
