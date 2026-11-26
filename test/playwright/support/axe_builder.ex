defmodule AshEnterpriseWeb.Specs.AxeBuilder do
  @moduledoc """
  `@axe-core/playwright`'s `AxeBuilder`, as far as the specs use it (`include/2`,
  `with_tags/2` and `analyze!/1`): it evaluates the axe-core in `assets/node_modules`
  (`npm ci --prefix assets`) in the page and runs `axe.run(context, options)`. The
  application's pages have no iframes, so the main frame is the whole page.
  """

  alias Playwright.Page

  defstruct [:page, includes: [], option: %{}]

  def new(page), do: %__MODULE__{page: page}

  def include(builder, selector),
    do: %{builder | includes: builder.includes ++ [selector]}

  def with_tags(builder, tags),
    do: %{
      builder
      | option: Map.put(builder.option, :runOnly, %{type: "tag", values: List.wrap(tags)})
    }

  def analyze!(%__MODULE__{page: page, includes: includes, option: option}) do
    Page.evaluate!(page, script())
    context = if includes == [], do: %{exclude: []}, else: %{include: includes, exclude: []}
    Page.evaluate!(page, "([context, options]) => axe.run(context, options)", [context, option])
  end

  defp script do
    :persistent_term.get({__MODULE__, :source}, nil) ||
      (
        source = File.read!(axe_core_path())
        :persistent_term.put({__MODULE__, :source}, source)
        source
      )
  end

  # `require("axe-core").source`, which `@axe-core/playwright` injects.
  defp axe_core_path, do: Path.expand("../../../assets/node_modules/axe-core/axe.js", __DIR__)
end
