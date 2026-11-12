defmodule AshEnterprise.Accounts.Offboarding.Actions.Open do
  @moduledoc """
  Runs `AshEnterprise.Accounts.Offboarding.open`: the first step of the offboarding process.

  Reads the occurrence as the caller, so an occurrence of another organization is not found
  and one the caller may not read is refused. Anything but a `user.deactivated` occurrence is
  refused with the business error `not_a_deactivation`.

  Records the offboarding once per occurrence: a second run (a redelivery that got past the
  invocation, a re-drive) finds the row it wrote and answers with it.

  Answers `%{"offboarding_id" => id, "leaver" => "inactive" | "reactivated"}`.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshAgent.BusinessError
  alias AshEnterprise.Accounts.{Offboarding, User}
  alias AshEnterprise.Accounts.Offboarding.Holdings
  alias AshEnterprise.Automation.{Occurrence, Occurrences}

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)
    occurrence_id = input.arguments.id

    with {:ok, occurrence} <- deactivation(occurrence_id, opts),
         {:ok, offboarding} <- existing_or_record(occurrence, opts) do
      {:ok, answer(offboarding)}
    end
  end

  @doc false
  def answer(%Offboarding{} = offboarding) do
    %{"offboarding_id" => offboarding.id, "leaver" => Atom.to_string(offboarding.leaver_state)}
  end

  defp deactivation(id, opts) do
    case Ash.get(Occurrence, id, Keyword.put(opts, :not_found_error?, false)) do
      {:ok, %Occurrence{type: type, subject: subject} = occurrence}
      when is_binary(subject) ->
        if type == Occurrences.deactivated(),
          do: {:ok, occurrence},
          else: refuse("not_a_deactivation")

      {:ok, _none} ->
        refuse("not_a_deactivation")

      {:error, error} ->
        {:error, error}
    end
  end

  defp existing_or_record(occurrence, opts) do
    case existing(occurrence.id, opts) do
      {:ok, %Offboarding{} = offboarding} -> {:ok, offboarding}
      {:ok, nil} -> record(occurrence, opts)
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  def existing(occurrence_id, opts) do
    Offboarding
    |> Ash.Query.filter(occurrence_id == ^occurrence_id)
    |> Ash.read_one(opts)
  end

  defp record(occurrence, opts) do
    leaver_id = occurrence.subject
    state = leaver_state(leaver_id)

    holdings =
      if state == :inactive, do: Holdings.of(leaver_id, Keyword.fetch!(opts, :tenant)), else: %{}

    Offboarding
    |> Ash.Changeset.for_create(
      :record,
      %{
        occurrence_id: occurrence.id,
        leaver_id: leaver_id,
        leaver_state: state,
        holdings: holdings
      },
      opts
    )
    |> Ash.create()
  end

  @doc """
  `:inactive` while the user is not active (or is gone), `:reactivated` when they are active
  again. A lookup of one account's state by id, not an authorization decision.
  """
  @spec leaver_state(Ash.UUID.t()) :: :inactive | :reactivated
  def leaver_state(user_id) do
    User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.select([:id, :lifecycle_status])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{lifecycle_status: :active}} -> :reactivated
      {:ok, _inactive_or_gone} -> :inactive
      {:error, error} -> raise error
    end
  end

  defp refuse(code), do: {:error, BusinessError.exception(code: code)}
end
