defmodule AshEnterpriseWeb.Gettext.Pseudo do
  @moduledoc """
  A pseudo-translation of a msgid: every ASCII letter becomes an accented one,
  the text is padded by a third and bracketed, and `%{name}` placeholders are
  left alone for the bindings to fill.

      iex> AshEnterpriseWeb.Gettext.Pseudo.translate("Users")
      "⟦Ûšéŕš~⟧"

  Text a screen shows in the pseudo-locale that still has an ASCII word in it
  never went through Gettext. It is how `AshBrowserTests.Journeys` finds a
  string a French reader would have seen in English.
  """

  # GAP: a pseudo-locale for a Gettext backend is a generic transform with no
  # product noun; it moves to a package when a second host wants it (ADR 0070).

  @accents Map.new(
             Enum.zip(
               String.graphemes("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"),
               String.graphemes("áƀçðéƒĝĥíĵķļɱñöþǫŕšţûṽŵẋýžÁƁÇÐÉƑĜĤÍĴĶĻṀÑÖÞǪŔŠŢÛṼŴẊÝŽ")
             )
           )

  @spec translate(String.t()) :: String.t()
  def translate(msgid) do
    parts = Regex.split(~r/%\{\w+\}/, msgid, include_captures: true)
    text = for part <- parts, not placeholder?(part), do: part

    body = Enum.map_join(parts, &if(placeholder?(&1), do: &1, else: accent(&1)))
    padding = String.duplicate("~", div(String.length(Enum.join(text)), 3))

    "⟦" <> body <> padding <> "⟧"
  end

  defp placeholder?(part), do: String.starts_with?(part, "%{")

  defp accent(text), do: text |> String.graphemes() |> Enum.map_join(&Map.get(@accents, &1, &1))
end
