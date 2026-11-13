defmodule AshEnterprise.Automation.Occurrences do
  @moduledoc """
  The platform's writers of `AshEnterprise.Automation.Occurrence`: the only code that
  records one. They run as the `oban` system actor (`record` is machinery-only), never as
  the person the fact is about.

  ## Which organizations

  A user is not a tenant row (`User` is `tenant?: false`), so "the organizations a user
  belongs to" is read, across tenants and as the system actor, as the union of:

    1. the organization of the user's owning business unit (their home, the same answer
       `AshEnterprise.Security.ActorContext` gives when it resolves their tenant);
    2. the organizations of their live team memberships; and
    3. the organizations of their live role assignments.

  Archived memberships and assignments are not live and do not count. A user who belongs
  to none (a freshly registered one) gets no occurrence: there is no chain to write to.
  One occurrence is written per organization, each in that organization's own chain.

  ## What is recorded

  | `type` | When | `subject` | `data` |
  |---|---|---|---|
  | `user.deactivated` | after the `User` `:deactivate` action commits | the user's id | none |
  | `user.sign_in_refused` | after a password sign-in for a **known** user is refused | the user's id | `reason`: `bad_password`, `locked` or `deactivated`; `failures`: the consecutive failures the lockout counter holds for that identity, this one included, when it could be read |
  | `security.break_glass_approved` | after a `BreakGlassSession` `:approve` commits, which is what makes it usable | the operator's id | `session_id`, `acting_as` (the subject's id), `approver_id`, `minutes` (how long it is live) |
  | `accounts.api_key_issued` | after an `ApiKey` `:issue` commits | the owner's id | `key_id`, `expires_at` |
  | `alert.firing`, `alert.resolved` | an inbound SigNoz or GlitchTip alert, signed and verified (`AshEnterprise.Automation.AlertWebhook`) | none: an alert is about no person (`rule_id` in `data` names the rule or issue) | `provider`, `alertname`, `severity`, `category`, `rule_id` |

  No address, password, token or attempted credential is ever recorded, so `data` carries
  a reason and nothing that identifies what was typed.

  Break-glass sessions and API keys are `tenant?: false`, like `User`, so their own audit
  rows land in the chain no sweep reads; these occurrences are how a tenant's recipe sees
  them. A break-glass approval is recorded in the organizations of the person acted as
  (the tenant whose data it reaches), an API key in its owner's. An inbound alert is
  recorded in the one organization its webhook key maps to, and nowhere else.

  ## An unknown identity writes nothing

  A refused sign-in for an address that belongs to nobody records no occurrence. A row
  per unknown address would be a store of every string anyone typed into the sign-in box:
  an enumeration list, and a place where mistyped passwords end up. The existing lockout
  counter (`AshEnterprise.Accounts.Lockout`) keeps a digest for the same reason. A
  recipe cannot react to an attack on an address that is not an account, which is the
  intended reading.

  ## Delivery, and why it cannot change a refusal

  Both refusals and deactivations are detective: the write happens after the fact and
  never vetoes it.

    * A refusal's occurrences are written by a task under `AshEnterprise.TaskSupervisor`,
      started for **every** refusal, known or not, so the sign-in path costs the same
      either way and does not tell a caller whether an address is registered. The task
      does the lookup and the writes; the sign-in has already been answered. A failure in
      it (or a supervisor that is not running) is logged without the identity and never
      reaches the caller. A crash loses that occurrence; the refusal itself stands.
    * A deactivation's occurrences are written right after the deactivating transaction
      commits, in the caller's process. A failure is logged and the deactivation stands.
      A deactivation run inside a caller's own transaction would write inside it.

  ## Seams

  `config :ash_enterprise, AshEnterprise.Automation.Occurrences` accepts `:supervisor`
  (the task supervisor's name) and `:record` (a one-arity function taking the write's
  `{organization_id, attrs}`), so a test can make a write fail. Nothing in `config` sets
  either in a real deployment.
  """

  require Ash.Query
  require Logger

  alias AshEnterprise.Accounts.{BusinessUnit, TeamMembership, User}
  alias AshEnterprise.Automation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.UserRole

  @source "urn:ash-enterprise:accounts"
  @security_source "urn:ash-enterprise:security"
  @alerts_source "urn:ash-enterprise:alerts"
  @deactivated "user.deactivated"
  @refused "user.sign_in_refused"
  @break_glass "security.break_glass_approved"
  @api_key "accounts.api_key_issued"

  @doc """
  The `source` of the account facts: deactivations, refused sign-ins and API keys issued.
  A break-glass approval's is `security_source/0`, an inbound alert's `alerts_source/1`.
  """
  @spec source() :: String.t()
  def source, do: @source

  @doc "The `source` of a break-glass approval."
  @spec security_source() :: String.t()
  def security_source, do: @security_source

  @doc "The `source` of an inbound alert from `provider` (`signoz`, `glitchtip`)."
  @spec alerts_source(String.t()) :: String.t()
  def alerts_source(provider), do: "#{@alerts_source}:#{provider}"

  @doc "The `type` of a break-glass approval."
  @spec break_glass_approved() :: String.t()
  def break_glass_approved, do: @break_glass

  @doc "The `type` of an API key issued."
  @spec api_key_issued() :: String.t()
  def api_key_issued, do: @api_key

  @doc "The `type` of a deactivation."
  @spec deactivated() :: String.t()
  def deactivated, do: @deactivated

  @doc "The `type` of a refused sign-in."
  @spec sign_in_refused() :: String.t()
  def sign_in_refused, do: @refused

  @doc """
  The organizations `user` belongs to: home, live team memberships and live role
  assignments. Ids, unique, in no particular order. See the moduledoc.
  """
  @spec organizations_of(User.t() | Ash.UUID.t()) :: [Ash.UUID.t()]
  def organizations_of(%{id: id, owning_business_unit_id: unit_id}),
    do: organizations_of(id, unit_id)

  def organizations_of(user_id) when is_binary(user_id) do
    unit_id =
      User
      |> Ash.Query.filter(id == ^user_id)
      |> Ash.Query.select([:owning_business_unit_id])
      |> read_one()
      |> case do
        %{owning_business_unit_id: unit_id} -> unit_id
        _ -> nil
      end

    organizations_of(user_id, unit_id)
  end

  defp organizations_of(user_id, unit_id) do
    home =
      if unit_id do
        BusinessUnit
        |> Ash.Query.filter(id == ^unit_id)
        |> Ash.Query.select([:organization_id])
        |> read_one()
        |> case do
          %{organization_id: org} -> [org]
          _ -> []
        end
      else
        []
      end

    teams =
      TeamMembership
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.Query.select([:organization_id])
      |> read_all()

    roles =
      UserRole
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.Query.select([:organization_id])
      |> read_all()

    (home ++ Enum.map(teams ++ roles, & &1.organization_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Cross-tenant on purpose: the question is which tenants a person is in, and no one
  # tenant's scope can answer it. Ids only (`select`), as the system actor, the way the
  # trigger sweep enumerates the tenants that have a subscription.
  defp read_one(query),
    do: query |> Ash.read_one(actor: SystemActor.oban(), tenant: nil) |> ok_or(nil)

  defp read_all(query), do: query |> Ash.read(actor: SystemActor.oban(), tenant: nil) |> ok_or([])

  defp ok_or({:ok, value}, _default), do: value
  defp ok_or({:error, error}, _default), do: raise(error)

  @doc """
  Records that `user` was deactivated, once per organization. Call after the
  deactivating transaction commits. Never raises: a failure is logged and the
  deactivation stands. Returns `:ok`.
  """
  @spec user_deactivated(User.t()) :: :ok
  def user_deactivated(%{id: id} = user) do
    attrs = %{
      event_id: "#{@deactivated}:#{id}:#{Map.get(user, :version_number)}",
      type: @deactivated,
      subject: id,
      data: %{}
    }

    safely(fn -> write_all(organizations_of(user), attrs) end)
  end

  @doc """
  Hands a refused password sign-in to the task that records it, and returns at once.

  `locked?` says whether the identity was already locked when the attempt began (the
  caller knows; the task cannot reconstruct it, because the failed attempt may itself
  lock the identity). `failures` is the lockout counter's count after this failure, when
  the caller could read it (`nil` otherwise): the consecutive failures within the lockout
  window, which a recipe's guard compares against a threshold. The task finds the user, if
  any, and writes one occurrence per organization typed by reason; no user, no write.
  Always `:ok`.
  """
  @spec sign_in_refused(term(), boolean(), non_neg_integer() | nil) :: :ok
  def sign_in_refused(identity, locked?, failures \\ nil) do
    config = Application.get_env(:ash_enterprise, __MODULE__, [])
    supervisor = Keyword.get(config, :supervisor, AshEnterprise.TaskSupervisor)

    try do
      Task.Supervisor.start_child(supervisor, fn ->
        safely(fn -> record_refusal(identity, locked?, failures) end)
      end)
    catch
      kind, _reason -> Logger.warning("Occurrences: refusal not recorded (#{kind})")
    end

    :ok
  end

  @doc false
  @spec record_refusal(term(), boolean(), non_neg_integer() | nil) :: :ok
  def record_refusal(identity, locked?, failures \\ nil) do
    case find_user(identity) do
      nil ->
        :ok

      user ->
        reason =
          cond do
            locked? -> "locked"
            user.lifecycle_status != :active -> "deactivated"
            true -> "bad_password"
          end

        data =
          if is_integer(failures),
            do: %{"reason" => reason, "failures" => failures},
            else: %{"reason" => reason}

        attrs = %{
          event_id: "#{@refused}:#{Ash.UUID.generate()}",
          type: @refused,
          subject: user.id,
          data: data
        }

        write_all(organizations_of(user), attrs)
    end
  end

  @doc """
  Records that a break-glass session was approved, which is what makes it usable, once
  per organization of the person it acts as. Call after the approving transaction
  commits. Never raises: a failure is logged and the approval stands. Returns `:ok`.
  """
  @spec break_glass_approved(struct()) :: :ok
  def break_glass_approved(%{id: id, operator_id: operator, subject_id: subject} = session) do
    attrs = %{
      event_id: "#{@break_glass}:#{id}",
      source: @security_source,
      type: @break_glass,
      subject: operator,
      data: %{
        "session_id" => id,
        "acting_as" => subject,
        "approver_id" => Map.get(session, :approver_id),
        "minutes" => minutes(session)
      }
    }

    safely(fn -> write_all(organizations_of(subject), attrs) end)
  end

  defp minutes(%{started_at: %DateTime{} = from, expires_at: %DateTime{} = until}),
    do: DateTime.diff(until, from, :minute)

  defp minutes(_session), do: nil

  @doc """
  Records that an API key was issued, once per organization of its owner. Call after the
  issuing transaction commits. Never raises: a failure is logged and the key stands.
  Nothing about the key but its id and expiry is recorded. Returns `:ok`.
  """
  @spec api_key_issued(struct()) :: :ok
  def api_key_issued(%{id: id, user_id: owner} = key) do
    attrs = %{
      event_id: "#{@api_key}:#{id}",
      type: @api_key,
      subject: owner,
      data: %{"key_id" => id, "expires_at" => iso8601(Map.get(key, :expires_at))}
    }

    safely(fn -> write_all(organizations_of(owner), attrs) end)
  end

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(_other), do: nil

  @doc """
  Records inbound alerts in one organization, the one the webhook key that signed them
  maps to (`AshEnterprise.Automation.AlertWebhook`). Each entry is an occurrence's
  attributes without `source` and `time`'s default; `provider` names the source.

  Returns `{:ok, created}` with the number of alerts that were new (a replay of one already
  recorded is not), or `{:error, reason}` when a write failed. Unlike the other writers it
  reports a failure, because a webhook caller is told to deliver again.
  """
  @spec record_alerts(Ash.UUID.t(), String.t(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def record_alerts(organization, provider, alerts) when is_list(alerts) do
    source = alerts_source(provider)
    now = DateTime.utc_now()

    Enum.reduce_while(alerts, {:ok, 0}, fn alert, {:ok, created} ->
      attrs = alert |> Map.put(:source, source) |> Map.put_new(:time, now)

      case write_new(organization, attrs) do
        :created -> {:cont, {:ok, created + 1}}
        :existing -> {:cont, {:ok, created}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp write_new(organization, attrs) do
    case Automation.record_occurrence(attrs, actor: SystemActor.oban(), tenant: organization) do
      {:ok, _row} -> :created
      {:error, error} -> if recorded?(organization, attrs), do: :existing, else: {:error, error}
    end
  rescue
    exception -> {:error, exception}
  end

  # Any state, so a deactivated user is known. A lookup, not a sign-in: nothing
  # here checks a password.
  defp find_user(identity) do
    with email when is_binary(email) <- text(identity),
         %{} = user <-
           User
           |> Ash.Query.filter(email == ^email)
           |> Ash.Query.select([:id, :owning_business_unit_id, :lifecycle_status])
           |> read_one() do
      user
    else
      _ -> nil
    end
  end

  defp text(identity) when is_binary(identity) or is_struct(identity, Ash.CiString),
    do: identity |> to_string() |> String.trim()

  defp text(_other), do: nil

  defp write_all(organizations, attrs) do
    now = DateTime.utc_now()

    for organization <- organizations do
      write_one({organization, attrs |> Map.put_new(:source, @source) |> Map.put(:time, now)})
    end

    :ok
  end

  defp write_one(write) do
    config = Application.get_env(:ash_enterprise, __MODULE__, [])

    case Keyword.get(config, :record) do
      nil -> record(write)
      fun when is_function(fun, 1) -> fun.(write)
    end
  end

  defp record({organization, attrs}) do
    case Automation.record_occurrence(attrs, actor: SystemActor.oban(), tenant: organization) do
      {:ok, _row} -> :ok
      {:error, error} -> duplicate_or_raise(organization, attrs, error)
    end
  end

  # Writing the same fact twice is one row (the envelope identity).
  defp duplicate_or_raise(organization, attrs, error) do
    if recorded?(organization, attrs), do: :ok, else: raise(error)
  end

  defp recorded?(organization, attrs) do
    AshEnterprise.Automation.Occurrence
    |> Ash.Query.filter(source == ^attrs.source and event_id == ^attrs.event_id)
    |> Ash.exists?(actor: SystemActor.oban(), tenant: organization)
  end

  defp safely(fun) do
    fun.()
    :ok
  rescue
    exception ->
      Logger.warning("Occurrences: not recorded (#{inspect(exception.__struct__)})")
      :ok
  catch
    kind, _reason ->
      Logger.warning("Occurrences: not recorded (#{kind})")
      :ok
  end
end
