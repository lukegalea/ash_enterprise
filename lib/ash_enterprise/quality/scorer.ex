defmodule AshEnterprise.Quality.Scorer do
  @moduledoc """
  A deterministic scorer (ADR 0058): one dimension of how an agent answered, measured
  from what its run recorded and never from a model.

  `measure/2` gets the assertion and what the run recorded
  (`t:AshEnterprise.Quality.Assertions.observed/0`) and says `:passed`, `:failed` or
  `:unmeasured`, with a detail that never carries the answer or an argument, and
  optionally a `measure` map of counts (`%{"hit" => 2, "of" => 3}`) for rates that a
  pass or a fail would hide. `AshEnterprise.Quality.Assertions` routes each assertion
  type to its scorer.
  """

  @type status :: :passed | :failed | :unmeasured

  @callback measure(assertion :: map(), observed :: map()) ::
              {status(), String.t()} | {status(), String.t(), map()}
end
