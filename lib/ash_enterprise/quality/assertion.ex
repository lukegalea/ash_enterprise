defmodule AshEnterprise.Quality.Assertion do
  @moduledoc """
  One deterministic assertion of a suite case (ADR 0058): what a case's run must or
  must not have done, from the closed vocabulary in `AshEnterprise.Quality.Assertions`.

    * `type`: the assertion;
    * `target`: the action it is about, as `"Resource.Module.action"` (`tool_called`,
      `tool_not_called`, `args_match`, `prohibited_effect`, `approval_requested`);
    * `args`: the arguments a call must have had, at least (`args_match`);
    * `expected`: what the answer must hold (`output_matches`);
    * `limit`: the most model calls the run may make (`max_steps`);
    * `any_of`: other tools that satisfy a `tool_called` as well as `target`.

  `args` values are literals or matchers (`AshEnterprise.Quality.Scorers.ArgMatch`).
  `expected` also carries what `facts` (`"facts"`), `cites` (`"refs"`) and `proposal`
  (`"kind"`) are measured against.

  `AshEnterprise.Quality.Assertions.problems/1` says what an assertion is missing.
  """

  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        type: [
          type: :atom,
          allow_nil?: false,
          constraints: [
            one_of: [
              :tool_called,
              :tool_not_called,
              :args_match,
              :prohibited_effect,
              :approval_requested,
              :max_steps,
              :within_budget,
              :process_transition,
              :schema_valid,
              :output_matches,
              :cites,
              :facts,
              :surface,
              :proposal,
              :calls_accepted
            ]
          ]
        ],
        target: [type: :string, constraints: [max_length: 512]],
        args: [type: :map],
        expected: [type: :map],
        limit: [type: :integer, constraints: [min: 0]],
        any_of: [type: {:array, :string}]
      ]
    ]
end
