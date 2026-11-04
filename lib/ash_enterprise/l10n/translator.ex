defmodule AshEnterprise.L10n.Translator do
  @moduledoc """
  What `AshEnterprise.L10n.Generator` asks a model for: one bounded batch of
  catalog messages in, their translations out.

  The request is a plain map, the same for every implementation:

      %{
        locale: "fr",                    # the Gettext locale being written
        domain: "default",               # the catalog
        nplurals: 2,                     # plural forms the locale's catalog has
        glossary: %{"Today" => "Aujourd'hui"},
        items: [
          %{id: "1", msgid: "Admin", msgid_plural: nil, msgctxt: nil,
            comments: ["lib/ash_enterprise_web/components/layouts.ex:140"]}
        ]
      }

  The answer is the decoded structured output, **untrusted**: the generator
  validates every field (`AshEnterprise.L10n.Validator`) before a byte of it
  reaches a PO file. It is expected to look like

      %{"translations" => [
        %{"id" => "1", "msgid" => "Admin", "msgstr" => "Administration"},
        %{"id" => "2", "msgid" => "%{count} linked", "msgstr_plural" => ["%{count} lié", "%{count} liés"]}
      ]}

  `AshEnterprise.L10n.Translator.ReqLLM` is the real one. Tests pass a fake;
  nothing in a test or in CI calls a model.
  """

  @type item :: %{
          id: String.t(),
          msgid: String.t(),
          msgid_plural: String.t() | nil,
          msgctxt: String.t() | nil,
          comments: [String.t()]
        }

  @type request :: %{
          locale: String.t(),
          domain: String.t(),
          nplurals: pos_integer(),
          glossary: %{String.t() => String.t()},
          items: [item()]
        }

  @callback translate(request(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
end
