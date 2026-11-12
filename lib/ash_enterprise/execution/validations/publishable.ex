defmodule AshEnterprise.Execution.Validations.Publishable do
  @moduledoc """
  What this application requires of a published agent version, beyond the fragment's
  own checks (`AshAgent.AgentVersion.Definition.publish_problems/1`):

    * the model profile is the in-zone generative profile (ADR 0042): no agent is
      published to run on a model outside the deployment's zone;
    * an automation authority names a principal this build declares
      (`AshEnterprise.Platform.AutomationPrincipal`, ADR 0043), and not `recipe_runner`,
      which runs only a recipe's standing grant (ADR 0069): an agent version running as it
      would borrow the roles a tenant gave its recipes.

  `problems/2` is the same check for a caller that has the version and the publish-time
  choices in hand, such as `AshEnterprise.Execution.Actions.RequestPublish` before it
  opens an approval.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.AI.Models
  alias AshEnterprise.Platform.AutomationPrincipal

  @impl true
  def validate(changeset, _opts, _context) do
    case problems(changeset.data, Ash.Changeset.get_argument(changeset, :authority)) do
      [] -> :ok
      [problem | _] -> {:error, message: "cannot publish: #{problem}"}
    end
  end

  @doc "Why `version` cannot be published here with `authority`, as messages."
  @spec problems(map(), map() | nil) :: [String.t()]
  def problems(version, authority) do
    profile(version.model_profile) ++ principal(authority)
  end

  defp profile(profile) do
    if profile == Models.in_zone_profile_name(),
      do: [],
      else: [
        "model_profile #{inspect(profile)} is not the in-zone profile " <>
          "(#{inspect(Models.in_zone_profile_name())})"
      ]
  end

  defp principal(authority) when is_map(authority) do
    authority = Map.new(authority, fn {key, value} -> {to_string(key), value} end)

    if authority["type"] in ["automation", :automation],
      do: declared(authority["name"]),
      else: []
  end

  defp principal(_requester), do: []

  defp declared(name) do
    case AutomationPrincipal.fetch(name) do
      {:ok, %AutomationPrincipal{name: :recipe_runner}} ->
        ["recipe_runner runs only a recipe's standing grant, never an agent version"]

      {:ok, _declared} ->
        []

      :error ->
        [
          "#{inspect(name)} is not an automation principal this application declares"
        ]
    end
  end
end
