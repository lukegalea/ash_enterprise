defmodule AshEnterprise.Documents.PaperClause.Validations.WellFormedRuns do
  @moduledoc """
  A clause's runs are `%{"kind" => "text" | "hole", "value" => string}` maps and
  nothing else: the kind names how `AshPaper.Clause.resolve/3` reads the run,
  and a `"hole"` value names a payload field the render fills. A malformed run
  would surface mid-render as an unreadable clause; it is refused at drafting,
  where the author is looking. The test is the kernel's own
  (`AshPaper.Clause.valid_runs?/1`), so what is admitted is what renders.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :runs) do
      runs when is_list(runs) ->
        if AshPaper.Clause.valid_runs?(runs) do
          :ok
        else
          message = "each run must be a map with kind \"text\" or \"hole\" and a string value"
          {:error, field: :runs, message: message}
        end

      _other ->
        {:error, field: :runs, message: "must be a list of runs"}
    end
  end
end
