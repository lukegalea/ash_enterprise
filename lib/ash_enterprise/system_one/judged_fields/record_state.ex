defmodule AshEnterprise.SystemOne.JudgedFields.RecordState do
  @moduledoc """
  The state projection for questions about a record's own fields: the
  judge sees exactly the `input` map it is given — the record's projection
  fields as `AshEnterprise.SystemOne.JudgedFields.state_input/2` builds
  them — and nothing else. The question's declared `state_shape` names
  those fields, so what the model can see is the declaration.
  """

  @behaviour AshJudgments.Registry.StateProjection

  @impl true
  def project(input, _context), do: input.arguments.input
end
