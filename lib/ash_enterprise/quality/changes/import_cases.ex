defmodule AshEnterprise.Quality.Changes.ImportCases do
  @moduledoc """
  Appends cases read from another format to a draft suite: `format: :samples` reads the
  `jsonl` argument (`AshEnterprise.Quality.Interchange.Samples`), `format: :promptfoo`
  the `yaml` argument (`AshEnterprise.Quality.Interchange.Promptfoo`). A line or test that
  cannot be read refuses the whole import, naming it.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Quality.Interchange.{Promptfoo, Samples}

  @impl true
  def init(opts) do
    if opts[:format] in [:samples, :promptfoo],
      do: {:ok, opts},
      else: {:error, "format must be :samples or :promptfoo"}
  end

  @impl true
  def change(changeset, opts, _context) do
    result =
      case opts[:format] do
        :samples -> Samples.parse(Ash.Changeset.get_argument(changeset, :jsonl))
        :promptfoo -> Promptfoo.parse(Ash.Changeset.get_argument(changeset, :yaml))
      end

    case result do
      {:ok, cases} ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :cases,
          (changeset.data.cases || []) ++ cases
        )

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :cases, message: message)
    end
  end
end
