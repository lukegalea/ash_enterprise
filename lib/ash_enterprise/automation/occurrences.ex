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
  | `user.sign_in_refused` | after a password sign-in for a **known** user is refused | the user's id | `reason`: `bad_password`, `locked` or `deactivated` |

  No address, password, token or attempted credential is ever recorded, so `data` carries
  a reason and nothing that identifies what was typed.

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
  @deactivated "user.deactivated"
  @refused "user.sign_in_refused"

  @doc "The `source` of every occurrence these writers record."
  @spec source() :: String.t()
  def source, do: @source

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
  lock the identity). The task finds the user, if any, and writes one occurrence per
  organization typed by reason; no user, no write. Always `:ok`.
  """
  @spec sign_in_refused(term(), boolean()) :: :ok
  def sign_in_refused(identity, locked?) do
    config = Application.get_env(:ash_enterprise, __MODULE__, [])
    supervisor = Keyword.get(config, :supervisor, AshEnterprise.TaskSupervisor)

    try do
      Task.Supervisor.start_child(supervisor, fn ->
        safely(fn -> record_refusal(identity, locked?) end)
      end)
    catch
      kind, _reason -> Logger.warning("Occurrences: refusal not recorded (#{kind})")
    end

    :ok
  end

  @doc false
  @spec record_refusal(term(), boolean()) :: :ok
  def record_refusal(identity, locked?) do
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

        attrs = %{
          event_id: "#{@refused}:#{Ash.UUID.generate()}",
          type: @refused,
          subject: user.id,
          data: %{"reason" => reason}
        }

        write_all(organizations_of(user), attrs)
    end
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
      write_one({organization, attrs |> Map.put(:source, @source) |> Map.put(:time, now)})
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
    exists? =
      AshEnterprise.Automation.Occurrence
      |> Ash.Query.filter(source == ^attrs.source and event_id == ^attrs.event_id)
      |> Ash.exists?(actor: SystemActor.oban(), tenant: organization)

    if exists?, do: :ok, else: raise(error)
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
