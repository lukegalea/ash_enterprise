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

  ## Not yet carried

  The rows are written under the linked account's owner and tenant, but not
  under its shred scope: `Conversation`/`Message`/`Person` have no scope column
  yet. `context.scope` is computed and is where the per-scope encryption work
  plugs in.
  """

  alias AshEnterprise.Canonical.{Conversation, Message, Person}
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.{Landing, LinkedAccount}
  alias AshEnterprise.Integration.Slack.Records
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Zones

  require Ash.Query

  # Notices about the conversation rather than messages in it: landed raw,
  # not projected.
  @projected_subtypes [nil, "thread_broadcast", "file_share", "bot_message", "me_message"]

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
  `linked_account`. Records of another linked account are ignored.
  """
  @spec project([map()], struct(), keyword()) ::
          {:ok, counts()} | {:error, term()}
  def project(records, %LinkedAccount{} = account, opts \\ []) do
    with :ok <- admit() do
      context = context(account)

      streams =
        records
        |> Enum.filter(&(get_in(&1.source_metadata, ["linked_account_id"]) == account.id))
        |> Enum.sort_by(& &1.external_id)
        |> Enum.group_by(&get_in(&1.source_metadata, ["stream"]))

      conversations =
        streams
        |> Map.get(Records.stream(:conversations), [])
        |> Map.new(&{&1.raw_payload["id"], &1.raw_payload})

      messages =
        streams
        |> Map.get(Records.stream(:messages), [])
        |> Enum.map(&{get_in(&1.source_metadata, ["channel_id"]), &1.raw_payload})
        |> Enum.filter(fn {channel, message} ->
          is_binary(channel) and Records.ts?(message["ts"])
        end)

      users =
        streams
        |> Map.get(Records.stream(:users), [])
        |> Map.new(&{&1.raw_payload["id"], &1.raw_payload})

      self_user_id =
        Keyword.get_lazy(opts, :self_user_id, fn -> infer_self(conversations, messages) end)

      people = project_people(users, context)

      public =
        Map.filter(conversations, fn {_id, conversation} -> public_channel?(conversation) end)

      public_messages =
        Enum.filter(messages, fn {channel, _} -> Map.has_key?(public, channel) end)

      conversation_rows = project_conversations(public, public_messages, users, people, context)

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

  defp project_conversations(conversations, messages, users, people, context) do
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
            participants: participants
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
        sender_id: people |> person_id(author) |> List.first()
      },
      tenant: context.tenant_id,
      authorize?: false
    )
    # `Message.upsert_from_source` does not accept the owner context (Person's
    # does), but a user-owned row must have one, so it is forced onto the
    # validated changeset. On a conflict the owner is not in `upsert_fields`,
    # so the first projection wins, as everywhere else in this domain.
    |> Ash.Changeset.force_change_attributes(%{
      owner_id: context.owner_id,
      owner_type: :user,
      owning_user_id: context.owner_id,
      owning_business_unit_id: context.business_unit_id
    })
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
      tenant_id: account.organization_id,
      scope: Landing.scope(account)
    }
  end
end
