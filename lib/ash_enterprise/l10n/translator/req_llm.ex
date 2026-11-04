defmodule AshEnterprise.L10n.Translator.ReqLLM do
  @moduledoc """
  The real `AshEnterprise.L10n.Translator`: one `ReqLLM.generate_object/4`
  call per batch, constrained by a JSON schema, at temperature 0.

  The model is `opts[:model]` (`mix l10n.generate --model`), else the
  interpreter model (`AshEnterprise.AI.model/0`).

  It sends only what is already in this repository: catalog msgids, their
  source references and the glossary. No tenant data, no record, no actor. So
  it calls ReqLLM directly rather than through
  `AshEnterprise.AI.Models.GuardedReqLLM`, whose residency guard and call
  record (ADR 0042) govern customer data and write to the application's
  database, which a design-time task does not start.

  Never called from a test or from CI: tests pass a fake translator.
  """

  @behaviour AshEnterprise.L10n.Translator

  @schema %{
    "type" => "object",
    "properties" => %{
      "translations" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string"},
            "msgid" => %{"type" => "string"},
            "msgstr" => %{"type" => "string"},
            "msgstr_plural" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["id", "msgid"]
        }
      }
    },
    "required" => ["translations"]
  }

  @impl true
  def translate(request, opts) do
    model = Keyword.get(opts, :model) || AshEnterprise.AI.model()

    with {:ok, response} <-
           ReqLLM.generate_object(model, prompt(request), @schema,
             system_prompt: system_prompt(request),
             temperature: 0.0
           ) do
      # Keys as strings whatever the decoder chose: the validator reads them so.
      {:ok, response |> ReqLLM.Response.object() |> Jason.encode!() |> Jason.decode!()}
    end
  end

  @doc false
  def system_prompt(request) do
    """
    You translate the user interface of a business web application from English
    into the locale `#{request.locale}`. The strings come from a gettext catalog
    (domain `#{request.domain}`).

    Rules:
    - Answer with exactly one translation per item, echoing its `id` and `msgid`
      unchanged. Do not add, skip or merge items.
    - Keep every placeholder written as %{name} exactly as it is, untranslated.
      Add none.
    - For an item with `msgid_plural`, answer `msgstr_plural` with exactly
      #{request.nplurals} forms, in the locale's gettext plural order; otherwise
      answer `msgstr`.
    - Never leave a translation empty. Keep product names, keyboard shortcuts
      (ctrl k), code and file names as they are.
    - Match the register of professional software in that locale: concise,
      neutral, the formal second person where the language has one.
    - Use the glossary's translations for its terms wherever they appear.
    """
  end

  @doc false
  def prompt(request) do
    Jason.encode!(
      %{
        "glossary" => request.glossary,
        "items" =>
          Enum.map(request.items, fn item ->
            item
            |> Map.take([:id, :msgid, :msgid_plural, :msgctxt, :comments])
            |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
            |> Map.new()
          end)
      },
      pretty: true
    )
  end
end
