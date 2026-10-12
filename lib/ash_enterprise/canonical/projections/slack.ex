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

  Slack content is personal and confidential data. **Nothing is projected**
  unless the deployment declares the zone the canonical store lives in and the
  tags Slack data carries:

      config :ash_enterprise, AshEnterprise.Canonical.Projections.Slack,
        zone: "my-zone",              # a zone id declared under AshEnterprise.Zones
        data_class: :customer_confidential,
        residency: "CA"

  With no zone (the default), an undeclared zone, untagged data or tags the
  zone cannot hold, `project/3` and `replay/2` return `{:error, {:not_admitted,
  reason}}` and write nothing — checked before a single raw row is read.

  ## Only public channels, for now

  `Conversation` is **organization-owned**: any member with a read grant on it
  sees every row. A DM's subject (`"Direct message with <name>"`) or a private
  channel's name, and the participants' emails, are one user's private data,
  so IMs, MPIMs and private channels are **not projected** — neither the
  conversation nor its messages — until `Conversation` can carry a per-user
  owner. A conversation is public only when its landed `conversations.list`
  record says so (`is_channel`, `is_private: false`, not an IM or MPIM);
  messages of a conversation with no landed record are not projected either,
  because nothing says it is public. They stay landed raw, under the account's
  shred scope.

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
  and email are `sensitive?`, so the audit log records them as `nil`).
  """

  alias AshEnterprise.Canonical.{Conversation, Message, Person}
  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Integration.Slack.Records
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Zones

  require Ash.Query

  # Notices about the conversation rather than messages in it: landed raw,
  # not projected.
  @projected_subtypes [nil, "thread_broadcast", "file_share", "bot_message", "me_message"]

  # Where a message's erasure scope rides alongside its payload inside this
  # module. Not a Slack key; never written anywhere.
  @scope_key "__erasure_scope_id__"

  @type counts :: %{
          conversations: non_neg_integer(),
          messages: non_neg_integer(),
          people: non_neg_integer()
        }

  @doc """
  Whether Slack data may enter the canonical store's zone, under the configured
  tags. `:ok`, or `{:error, {:not_admitted, reason}}` naming the rule, never
  the data.
  """
  @spec admit() :: :ok | {:error, {:not_admitted, atom()}}
  def admit do
    config = Application.get_env(:ash_enterprise, __MODULE__, [])
    tags = %{data_class: config[:data_class], residency: config[:residency]}

    case Zones.admit(config[:zone], tags) do
      :ok -> :ok
      {:error, %{reason: reason}} when is_atom(reason) -> {:error, {:not_admitted, reason}}
      {:error, _undeclared} -> {:error, {:not_admitted, :undeclared_zone}}
    end
  end

  @doc """
  Replay everything landed for one of the actor's own Slack linked accounts
  (or their only one, when `linked_account_id` is nil).
  """
  @spec replay(struct(), Ash.UUID.t() | nil, keyword()) ::
          {:ok, counts()} | {:error, term()}
  def replay(actor, linked_account_id \\ nil, opts \\ []) do
    with :ok <- admit(),
         {:ok, account} <- own_account(actor, linked_account_id) do
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
  records whose scope is shredded or unknown (see "Erasure").

  Options: `:self_user_id`, `:erasure_scope_id` (the scope `SourceRecord`s,
  which carry none of their own, were landed under).
  """
  @spec project([map()], struct(), keyword()) ::
          {:ok, counts()} | {:error, term()}
  def project(records, %LinkedAccount{} = account, opts \\ []) do
    with :ok <- admit() do
      context = context(account)
      default_scope = Keyword.get(opts, :erasure_scope_id)

      streams =
        records
        |> Enum.filter(&(get_in(&1.source_metadata, ["linked_account_id"]) == account.id))
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

      users =
        streams
        |> Map.get(Records.stream(:users), [])
        |> Map.new(fn {record, _scope_id} -> {record.raw_payload["id"], record.raw_payload} end)

      self_user_id =
        Keyword.get_lazy(opts, :self_user_id, fn -> infer_self(conversations, messages) end)

      people = project_people(users, context)

      public =
        Map.filter(conversations, fn {_id, conversation} -> public_channel?(conversation) end)

      public_messages =
        Enum.filter(messages, fn {channel, _} -> Map.has_key?(public, channel) end)

      conversation_rows =
        project_conversations(
          public,
          conversation_scopes,
          public_messages,
          users,
          people,
          context
        )

      projected =
        public_messages
        |> Enum.filter(fn {_channel, message} -> message["subtype"] in @projected_subtypes end)
        |> Enum.map(&project_message(&1, conversation_rows, people, self_user_id, context))

      {:ok,
       %{
         conversations: map_size(conversation_rows),
         messages: length(projected),
         people: map_size(people)
       }}
    end
  end

  # --- people ---------------------------------------------------------------------

  defp project_people(users, context) do
    users
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {user_id, user} ->
      case email(user) do
        nil -> []
        email -> [{user_id, upsert_person(email, display_name(user), context)}]
      end
    end)
    |> Map.new(fn {user_id, person} -> {user_id, person} end)
  end

  defp upsert_person(email, name, context) do
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
    |> Ash.create!(
      upsert?: true,
      upsert_identity: :unique_email,
      upsert_fields: if(name in [nil, ""], do: [], else: [:name])
    )
  end

  defp email(%{"profile" => %{"email" => email}}) when is_binary(email) do
    case String.trim(email) do
      "" -> nil
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
  end

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

    Map.new(channels, fn channel ->
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

      row =
        Conversation
        |> Ash.Changeset.for_create(
          :upsert_from_source,
          %{
            external_system: Records.external_system(),
            external_id: Records.conversation_id(context.linked_account_id, channel),
            subject: subject(conversation),
            participants: participants,
            erasure_scope_id: Map.fetch!(scopes, channel)
          },
          tenant: context.tenant_id,
          authorize?: false
        )
        |> Ash.create!()

      {channel, row}
    end)
  end

  defp subject(%{"name" => name}) when is_binary(name) and name != "", do: "#" <> name
  defp subject(_conversation), do: nil

  # --- messages ------------------------------------------------------------------------

  defp project_message({channel, message}, conversations, people, self_user_id, context) do
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
        conversation_id: conversations |> Map.fetch!(channel) |> Map.get(:id),
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
    |> Ash.create!()
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
      linked_account_id: account.id,
      owner_id: account.owner_id,
      business_unit_id: account.owning_business_unit_id,
      tenant_id: account.organization_id
    }
  end
end
