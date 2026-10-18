defmodule AshEnterprise.Canonical.Projections.Slack do
  @moduledoc """
  Raw Slack landings → canonical `Conversation`, `Message` and `Person` rows
  (epic E4, Slack vertical; ADR 0037's host-declared projection pattern).

  Input is what the Slack sync landed for **one linked account**
  (`AshEnterprise.Integration.Slack.Records`): the `slack.conversations`,
  `slack.messages` and `slack.users` streams. Output:

    * one `Conversation` per public channel, private channel, group DM
      (MPIM) or DM with at least one message to project — `external_id` is
      the conversation record's id, `kind` which of the four it is (see
      "Every kind of conversation"), `subject` its display name, and
      `participants` the Slack user ids that appear in it, plus the emails and
      person ids resolved for them;
    * one `Message` per projected message — body is Slack's `text`, `sent_at`
      its `ts`, `direction` `:outbound` when the author is the account's own
      Slack user, `:inbound` otherwise; join/leave/topic notices are landed raw
      but not projected;
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

  ## Every kind of conversation

  Public channels, private channels, group DMs and DMs are all projected, the
  same way: through the same gate, sealed under the same scope, and
  owner-only — `Conversation`, `Message` and `Person` are user-owned and
  owner-only (`AshEnterprise.Security.Privilege.owner_only?/1`), so nothing
  projected here, a DM least of all, is readable by another user. The kind
  comes from the conversation's own landed `users.conversations` record
  (`kind/1`): `is_im` is a `:dm`, `is_mpim` a `:group_dm`, a private channel
  (`is_private`, and `is_channel` or the legacy `is_group`) a
  `:private_channel`, and `is_channel` with `is_private: false` a
  `:public_channel`. A record that says none of these, and the messages of a
  conversation with no landed record, are not projected; they stay landed
  raw, under the account's shred scope.

  A conversation is written only when it has a message to write, in a replay
  as in an incremental step, so a DM Slack lists with nothing in the backfill
  window never becomes an empty row.

  ## Names

  A channel's `subject` is `"#" <> name`. A DM's or group DM's is the other
  participants' names, sorted and joined with `", "`: a DM's other party is its
  record's `user`; a group DM's are the authors seen in it, less the account's
  own Slack user. Each name is the owner's `Person` for that member, else the
  member's own Slack profile, and the raw Slack user id only when neither has
  a name. A group DM with no other author yet is named after the member
  handles in its Slack name (`mpdm-alice--bob-1`). The subject is sealed like
  any other.

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
  alias AshEnterprise.Canonical.Projections.{Golden, Write, ZoneGate}
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

  # Whether a message is one of the records being counted (see `only:` under
  # `project/3`). Likewise internal only.
  @counted_key "__counted__"

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
  which carry none of their own, were landed under), `:only`.

  ## `only:` — the incremental form

  `only:` (a set of `external_id`s) is how a sync step projects just what it
  landed (`AshEnterprise.Canonical.Projections.Pending`). A conversation's
  participants come from every message in it, a message's sender from the
  member records, and the account's own Slack user from its IMs, so the step
  passes the new records together with that context (`with_context/2`) and
  names the new ones in `only:`. Then:

    * a `Person` is written only for an `only:` member record; the other
      members link to the `Person` the owner already has for their email, if
      any (read, never written);
    * a `Conversation` is written only when it has at least one new message
      to project, with its participants (and so a DM's name) from every
      message passed in;
    * only `only:` messages are written;
    * every count is about the `only:` records, or the rows written for them;
      records outside `only:` go through the zone gate (a refused one is never
      used) but their refusals are not counted.

  Without `only:` every record passed in is both written and counted.
  """
  @spec project([map()], struct(), keyword()) :: {:ok, counts()}
  def project(records, %LinkedAccount{} = account, opts \\ []) do
    context = context(account)
    gate = ZoneGate.configured(__MODULE__)

    {counted, context_records} =
      records
      |> Enum.filter(&(get_in(&1.source_metadata, ["linked_account_id"]) == account.id))
      |> Enum.split_with(counted_fun(Keyword.get(opts, :only)))

    {admitted, denied_by} = ZoneGate.partition(gate, counted, context)
    {admitted_context, _not_counted} = ZoneGate.partition(gate, context_records, context)

    ZoneGate.log_refusals(:slack, denied_by)

    marked =
      Enum.map(admitted, &{&1, true}) ++ Enum.map(admitted_context, &{&1, false})

    {:ok,
     marked
     |> project_admitted(context, Keyword.get(opts, :erasure_scope_id), opts)
     |> Map.merge(%{
       admitted: length(admitted),
       denied: denied_by |> Map.values() |> Enum.sum(),
       denied_by: denied_by
     })}
  end

  defp counted_fun(nil), do: fn _record -> true end
  defp counted_fun(%MapSet{} = only), do: &MapSet.member?(only, &1.external_id)
  defp counted_fun(only) when is_list(only), do: counted_fun(MapSet.new(only))

  @doc """
  The records an incremental projection of `delta` (records newly landed
  through `linked_account_id`) needs alongside it — see "`only:`" under
  `project/3`. When `delta` holds a message, that is every conversation record
  of the account, every message of the conversations it touches and of the
  account's IMs (for the account's own Slack user), and every member record;
  otherwise `delta` alone. Read through the decrypting path, as trusted
  infrastructure narrowed to the one account.
  """
  @spec with_context([map()], Ash.UUID.t()) :: [map()]
  def with_context(delta, linked_account_id) do
    channels =
      for record <- delta,
          get_in(record.source_metadata, ["stream"]) == Records.stream(:messages),
          channel = get_in(record.source_metadata, ["channel_id"]),
          is_binary(channel),
          uniq: true,
          do: channel

    if channels == [] do
      delta
    else
      conversations = landed(linked_account_id, :conversations)

      ims =
        for %{raw_payload: %{"is_im" => true, "id" => id}} <- conversations,
            is_binary(id),
            do: id

      messages = landed(linked_account_id, :messages, Enum.uniq(channels ++ ims))
      users = landed(linked_account_id, :users)

      Enum.uniq_by(delta ++ conversations ++ messages ++ users, & &1.external_id)
    end
  end

  defp landed(linked_account_id, kind, channels \\ nil) do
    stream = Records.stream(kind)

    SourceObject
    |> Ash.Query.filter(external_system == ^Records.external_system())
    |> Ash.Query.filter(source_metadata["linked_account_id"] == ^linked_account_id)
    |> Ash.Query.filter(source_metadata["stream"] == ^stream)
    |> then(fn query ->
      if channels,
        do: Ash.Query.filter(query, source_metadata["channel_id"] in ^channels),
        else: query
    end)
    |> Ash.Query.sort(:external_id)
    |> Ash.read!(authorize?: false)
  end

  defp project_admitted(marked, context, default_scope, opts) do
    streams =
      marked
      |> Enum.reject(fn {record, _counted?} -> Shredded.shredded?(record.raw_payload) end)
      |> Enum.map(fn {record, counted?} ->
        {record, Map.get(record, :erasure_scope_id) || default_scope, counted?}
      end)
      |> Enum.filter(fn {_record, scope_id, _counted?} -> is_binary(scope_id) end)
      |> Enum.sort_by(fn {record, _scope_id, _counted?} -> record.external_id end)
      |> Enum.group_by(fn {record, _scope_id, _counted?} ->
        get_in(record.source_metadata, ["stream"])
      end)

    conversation_records = Map.get(streams, Records.stream(:conversations), [])

    conversations =
      Map.new(conversation_records, fn {record, _scope_id, _counted?} ->
        {record.raw_payload["id"], record.raw_payload}
      end)

    conversation_scopes =
      Map.new(conversation_records, fn {record, scope_id, _counted?} ->
        {record.raw_payload["id"], scope_id}
      end)

    messages =
      streams
      |> Map.get(Records.stream(:messages), [])
      |> Enum.map(fn {record, scope_id, counted?} ->
        {get_in(record.source_metadata, ["channel_id"]),
         record.raw_payload
         |> Map.put(@scope_key, scope_id)
         |> Map.put(@counted_key, counted?)}
      end)
      |> Enum.filter(fn {channel, message} ->
        is_binary(channel) and Records.ts?(message["ts"])
      end)

    {new_users, known_users} =
      streams
      |> Map.get(Records.stream(:users), [])
      |> Enum.split_with(fn {_record, _scope_id, counted?} -> counted? end)

    users =
      Map.new(new_users ++ known_users, fn {record, _scope_id, _counted?} ->
        {record.raw_payload["id"], record.raw_payload}
      end)

    self_user_id =
      Keyword.get_lazy(opts, :self_user_id, fn -> infer_self(conversations, messages) end)

    {written_people, people_failed} = project_people(new_users, context)
    people = Map.merge(known_people(known_users, context), written_people)

    projectable =
      Map.filter(conversations, fn {_id, conversation} -> kind(conversation) != nil end)

    projectable_messages =
      Enum.filter(messages, fn {channel, _} -> Map.has_key?(projectable, channel) end)

    to_write =
      Enum.filter(projectable_messages, fn {_channel, message} ->
        message[@counted_key] and message["subtype"] in @projected_subtypes
      end)

    # A conversation is written only when it has a message to write: in a
    # replay as in an incremental step, so the two converge, and the many DMs
    # Slack lists with nothing in the backfill window never become empty rows.
    written_channels = Map.take(projectable, Enum.map(to_write, &elem(&1, 0)))

    {conversation_rows, conversations_failed} =
      project_conversations(
        written_channels,
        conversation_scopes,
        projectable_messages,
        %{users: users, people: people, self_user_id: self_user_id},
        context
      )

    {projected, messages_failed} =
      to_write
      |> Enum.map(&project_message(&1, conversation_rows, people, self_user_id, context))
      |> Enum.split_with(&match?({:ok, _}, &1))

    %{
      conversations: map_size(conversation_rows),
      messages: length(projected),
      people: map_size(written_people),
      failed: people_failed + conversations_failed + length(messages_failed)
    }
  end

  # The owner's existing people for members whose records are context, not
  # new: read, never written, so an incremental step does not rewrite every
  # member of every conversation it touches. One query for all of them.
  defp known_people([], _context), do: %{}

  defp known_people(user_records, context) do
    by_email =
      user_records
      |> Enum.flat_map(fn {record, _scope_id, _counted?} ->
        case email(record.raw_payload) do
          nil -> []
          email -> [{String.downcase(email), record.raw_payload["id"]}]
        end
      end)
      |> Map.new()

    emails = Map.keys(by_email)
    owner_id = context.owner_id

    Person
    |> Ash.Query.filter(email in ^emails and owner_id == ^owner_id)
    |> Ash.read!(tenant: context.tenant_id, authorize?: false)
    |> Enum.flat_map(fn person ->
      case Map.fetch(by_email, person.email |> to_string() |> String.downcase()) do
        {:ok, user_id} -> [{user_id, Golden.resolve(person, context.tenant_id)}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  # --- people ---------------------------------------------------------------------

  # One Person per member with an email, written only while the member
  # record's scope is live (checked under a lock a shred waits for,
  # `AshEnterprise.Erasure.LiveScope`): people are not sealed, so a shred
  # that committed after the landing must stop them being written at all.
  # Returns the people by Slack user id, and how many writes failed.
  defp project_people(user_records, context) do
    user_records
    |> Enum.sort_by(fn {record, _scope_id, _counted?} -> to_string(record.raw_payload["id"]) end)
    |> Enum.reduce({%{}, 0}, fn {record, scope_id, _counted?}, {people, failed} ->
      user = record.raw_payload

      with email when is_binary(email) <- email(user),
           {:ok, %Person{} = person} <- live_person(email, display_name(user), scope_id, context) do
        # Linked to the golden record when MDM merged this member's row.
        {Map.put(people, user["id"], Golden.resolve(person, context.tenant_id)), failed}
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
  # What sort of conversation the landed `users.conversations` record says this
  # is, or nil when it does not say (nothing is projected for it). IM and MPIM
  # flags first: an MPIM is also `is_group` and `is_private`.
  def kind(%{"is_im" => true}), do: :dm
  def kind(%{"is_mpim" => true}), do: :group_dm

  def kind(%{"is_private" => true} = conversation),
    do: if(channel?(conversation), do: :private_channel)

  def kind(%{"is_channel" => true, "is_private" => false}), do: :public_channel
  def kind(_conversation), do: nil

  # A modern private channel is `is_channel`; a legacy one is `is_group`.
  defp channel?(conversation),
    do: conversation["is_channel"] == true or conversation["is_group"] == true

  defp project_conversations(conversations, scopes, messages, naming, context) do
    authors_by_channel =
      Enum.group_by(messages, &elem(&1, 0), fn {_channel, message} -> message["user"] end)

    channels = conversations |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.sort()

    channels
    |> Enum.map(fn channel ->
      conversation = Map.fetch!(conversations, channel)
      kind = kind(conversation)

      user_ids =
        [conversation["user"] | Map.get(authors_by_channel, channel, [])]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()
        |> Enum.sort()

      participants = %{
        "slack_user_ids" => user_ids,
        "emails" =>
          user_ids
          |> Enum.flat_map(&List.wrap(email(Map.get(naming.users, &1, %{}))))
          |> Enum.sort(),
        "person_ids" => user_ids |> Enum.flat_map(&person_id(naming.people, &1)) |> Enum.sort()
      }

      Conversation
      |> Ash.Changeset.for_create(
        :upsert_from_source,
        %{
          external_system: Records.external_system(),
          external_id: Records.conversation_id(context.linked_account_id, channel),
          kind: kind,
          subject: subject(kind, conversation, user_ids, naming),
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

  # Channels by name; DMs and group DMs by who else is in them (sealed like
  # any subject).
  defp subject(kind, %{"name" => name}, _user_ids, _naming)
       when kind in [:public_channel, :private_channel] and is_binary(name) and name != "",
       do: "#" <> name

  defp subject(kind, conversation, user_ids, naming) when kind in [:dm, :group_dm] do
    case others(kind, conversation, user_ids, naming.self_user_id) do
      [] -> mpdm_handles(conversation)
      ids -> ids |> Enum.map(&member_name(&1, naming)) |> Enum.sort() |> Enum.join(", ")
    end
  end

  defp subject(_kind, _conversation, _user_ids, _naming), do: nil

  # A DM's other party is its record's `user` (the account holder, for a DM
  # with themselves). A group DM's are the participants seen in it, less the
  # account holder when known.
  defp others(:dm, %{"user" => counterpart}, _user_ids, _self)
       when is_binary(counterpart) and counterpart != "",
       do: [counterpart]

  defp others(_kind, _conversation, user_ids, self_user_id), do: user_ids -- [self_user_id]

  # The owner's Person for the member, else the member's own profile, else
  # (no name anywhere) the Slack user id.
  defp member_name(user_id, naming) do
    case Map.get(naming.people, user_id) do
      %Person{name: name} when is_binary(name) and name != "" ->
        name

      _ ->
        naming.users |> Map.get(user_id, %{}) |> display_name() || user_id
    end
  end

  # A group DM nobody else has written in yet: Slack names it after its
  # members' handles (`mpdm-alice--bob--carol-1`).
  defp mpdm_handles(%{"name" => "mpdm-" <> rest}) do
    rest
    |> String.replace(~r/-\d+\z/, "")
    |> String.split("--", trim: true)
    |> Enum.sort()
    |> Enum.join(", ")
    |> case do
      "" -> nil
      handles -> handles
    end
  end

  defp mpdm_handles(_conversation), do: nil

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
