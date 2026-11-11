defmodule AshEnterprise.Bpmn.Subscription.Validations.AuthoritySelectable do
  @moduledoc """
  What a draft's authority may be set to, and by whom.

  - `:standing_grant` is never set on a draft: a person's standing grant is their act at
    publish time.
  - `:causing_person` is chosen only by the platform's seed or process actor, which is the
    setup path, and only for an allowlisted key. A form acts for a person and a pack
    installs as one, so neither can select it.
  - `:human_tasks_only` may always be chosen.

  Reads the actor the call was made with, never input, and never queries.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Bpmn.Subscription.Authority
  alias AshEnterprise.Platform.SystemActor

  @impl true
  def validate(changeset, _opts, context) do
    case Ash.Changeset.get_attribute(changeset, :authority) do
      :standing_grant ->
        {:error,
         field: :authority,
         message: "a standing grant is published by the person accountable for it"}

      :causing_person ->
        key = Ash.Changeset.get_attribute(changeset, :key)

        cond do
          not system_actor?(context.actor) ->
            {:error,
             field: :authority,
             message: "only the setup path chooses the causing person; a person cannot"}

          not Authority.causing_person?(key) ->
            {:error,
             field: :authority,
             message:
               "#{inspect(key)} may not run as the causing person: it is not the one key " <>
                 "the causing_person_keys allowlist names"}

          true ->
            :ok
        end

      _other ->
        :ok
    end
  end

  # The setup task writes the seeded row as the platform's seed or process actor.
  defp system_actor?(%SystemActor{name: name}), do: name in [:seed, :process]
  defp system_actor?(_actor), do: false
end
