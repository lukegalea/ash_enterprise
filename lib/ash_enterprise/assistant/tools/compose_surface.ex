defmodule AshEnterprise.Assistant.Tools.ComposeSurface do
  @moduledoc """
  `Compose.compose_surface`: composes and verifies the requested surface
  (`AshEnterprise.Assistant.Composer`) and tells the model what was shown.

  The row's `surface` is the normalized request, which the page reads off the
  run's journal; the page composes it again, as the person, to render it.
  `covers` names the days a window resolved to ("Mon 19 Oct"), so the
  model can say which Monday it showed. A refusal is a short error the
  model can correct and retry, never a verifier's DSL message.
  """

  use Ash.Resource.ManualRead

  alias AshEnterprise.Assistant.{Compose, Composer}
  alias AshEnterprise.Assistant.Lookups.Support

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    Support.gated(query, context, fn _opts ->
      case Composer.compose(query.arguments) do
        {:ok, composed} ->
          {:ok,
           [
             Support.row(Compose, %{
               shown: composed.title,
               covers: composed.covers,
               surface: composed.request,
               notes: composed.notes,
               note:
                 "It is on the person's screen now, in this answer, read as them. Say in one " <>
                   "sentence what it shows; do not list its rows. They can pin it to their apps."
             })
           ]}

        {:error, reasons} ->
          {:error, "Not shown: " <> Enum.join(Enum.take(reasons, 4), "; ")}
      end
    end)
  end
end
