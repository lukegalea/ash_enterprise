defmodule AshEnterprise.Security.ActionReach do
  @moduledoc """
  Which of the policy set's paths reach an action, from the resource's
  `human_only:`, `machinery_only:` and `changes_authority:` declarations (ADR
  0059, ADR 0043).

  Three bypasses precede the grant union on every platform resource
  (`AshEnterprise.Security.Policies`): the process engine's, the decision
  engine's and the system actor's. A bypass covers every policy after it, so
  without these declarations an action meant for a person alone can still be
  run by a background job or by any call the engines mark as their own.

  | Declared | Engine bypasses | System-actor bypass | Grant union |
  |---|---|---|---|
  | nothing | reach | every system actor but `ai` | applies |
  | `human_only` | do not reach | does not reach | applies to people; a system actor gets nothing from it, nor does an automation principal (ADR 0043) |
  | `machinery_only` | do not reach | the `oban` system actor only | does not apply |
  | `changes_authority` | reach | as for nothing declared | applies, except to an automation principal |

  Every cell narrows a path that already exists; none adds a deny. A person's
  grants on a `human_only` action are exactly what they were.

  ## Never queries

  The declarations are compile-time DSL; the actor's name is on the struct the
  call was made with.
  """

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.ActorContext

  @doc "The actions `resource` declares human-only."
  @spec human_only(module()) :: [atom()]
  def human_only(resource),
    do: Spark.Dsl.Extension.get_opt(resource, [:platform], :human_only, [])

  @doc "The actions `resource` declares machinery-only."
  @spec machinery_only(module()) :: [atom()]
  def machinery_only(resource),
    do: Spark.Dsl.Extension.get_opt(resource, [:platform], :machinery_only, [])

  @doc "The actions `resource` declares change authority."
  @spec changes_authority(module()) :: [atom()]
  def changes_authority(resource),
    do: Spark.Dsl.Extension.get_opt(resource, [:platform], :changes_authority, [])

  @doc """
  Whether the grant union may authorize an automation principal on `action`: neither
  human-only nor one that changes authority (ADR 0043).
  """
  def automation?(resource, action),
    do: not human_only?(resource, action) and name(action) not in changes_authority(resource)

  @doc "True when only a person may run `action` on `resource`."
  def human_only?(resource, action), do: name(action) in human_only(resource)

  @doc "True when only the `oban` system actor may run `action` on `resource`."
  def machinery_only?(resource, action), do: name(action) in machinery_only(resource)

  @doc "Whether the engine bypasses reach `action`: neither human-only nor machinery-only."
  def engine?(resource, action),
    do: not human_only?(resource, action) and not machinery_only?(resource, action)

  @doc """
  Whether a system actor's authority reaches `action`.

  Asked only about an actor already known to be a system actor. A
  machinery-only action admits the `oban` system actor by name; an actor that
  arrives as a bare system `ActorContext` carries no name and is not admitted.
  """
  def system_actor?(actor, resource, action) do
    cond do
      human_only?(resource, action) -> false
      machinery_only?(resource, action) -> oban?(actor)
      true -> true
    end
  end

  @doc "Whether the grant union applies to `action`: every action but a machinery-only one."
  def grants?(resource, action), do: not machinery_only?(resource, action)

  defp oban?(%SystemActor{name: :oban}), do: true
  defp oban?(%ActorContext{}), do: false
  defp oban?(_actor), do: false

  defp name(%{name: name}), do: name
  defp name(name) when is_atom(name), do: name
end
