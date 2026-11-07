defmodule AshEnterprise.Assistant.Validations.ComposedSpec do
  @moduledoc """
  A pinned app's `spec` must be one the composer can show
  (`AshEnterprise.Assistant.Composer.reload/2`): it resolves against the
  allowlist as it is now, and `Composer.approved/1` finds nothing in it that
  could act. Checked when it is pinned and again every time it is opened, so
  nothing stored can name an operation a composed view does not declare.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Assistant.Composer

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :spec) do
      spec when is_binary(spec) ->
        case Composer.reload(spec) do
          {:ok, _surface} ->
            :ok

          {:error, reasons} ->
            {:error,
             field: :spec,
             message: "is not a view the agent can show: %{reasons}",
             vars: [reasons: Enum.join(reasons, " ")]}
        end

      _missing ->
        :ok
    end
  end
end
