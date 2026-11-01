defmodule AshEnterprise.Quality.Case do
  @moduledoc """
  One case of a suite (ADR 0058), in the shape of an Inspect `Sample`
  (https://inspect.aisi.org.uk/datasets.html.md): a stable `id`, the `input` the agent
  is asked, the `target` answer when there is one, and `metadata`; plus what this
  application adds:

    * `fixtures`: what the case's run is answered with when it asks for anything that is
      not a read, by target (`%{"Resource.Module.action" => result}`). A case runs with
      no effects, so a call its fixtures do not answer fails as `no_fixture`;
    * `split`: `:dev` or `:holdout`;
    * `tags`: such as `"injection"`;
    * `assertions`: what its run must or must not do (`AshEnterprise.Quality.Assertion`).
  """

  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        id: [type: :string, allow_nil?: false, constraints: [max_length: 255]],
        input: [type: :string, allow_nil?: false],
        target: [type: :string],
        metadata: [type: :map],
        fixtures: [type: :map],
        split: [type: :atom, constraints: [one_of: [:dev, :holdout]]],
        tags: [type: {:array, :string}],
        assertions: [type: {:array, AshEnterprise.Quality.Assertion}]
      ]
    ]
end
