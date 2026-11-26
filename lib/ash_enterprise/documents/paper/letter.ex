defmodule AshEnterprise.Documents.Paper.Letter do
  @moduledoc """
  The host's one layout: a letter that renders the payload's title, labelled
  fields and tables, then the clauses selected for it (version 2; version 1
  never printed them), with the kernel's page furniture (the footer lives in
  the page margin, outside the compared body region).

  Host-owned Typst, linted at compile time (`AshPaper.Layout.lint/1`) and
  locked by hash in `priv/paper.lock.json`. The only import it may name is
  the kernel's own `paper.typ`; everything else is data-driven from
  `payload.json` and `theme.json`, which the render pins.
  """

  use AshPaper.Layout,
    key: :letter,
    version: 2,
    path: Path.expand("../../../../priv/paper/layouts/letter.typ", __DIR__)
end
