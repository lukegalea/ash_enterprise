defmodule AshEnterprise.Agents.Actions.TodayReport do
  @moduledoc """
  The Today surface's report actions (`MorningBrief.agenda`, `.pulse`) and
  the ACP `today` digest (`Console.today`), delegating to
  `AshEnterprise.Agents.Today` with the calling actor's options.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Agents.Today

  @impl true
  def run(_input, opts, context) do
    ash_opts = Ash.Context.to_opts(context)

    case Keyword.fetch!(opts, :report) do
      :agenda -> Today.agenda(ash_opts)
      :pulse -> Today.pulse(ash_opts)
      :digest -> Today.digest(ash_opts)
    end
  end
end
