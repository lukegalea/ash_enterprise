defmodule AshEnterpriseWeb.Locale do
  @moduledoc """
  Which language a request is answered in (ADR 0060, section 5).

  ## Precedence

  The first source that names a locale with a catalog wins:

  1. **The person's own preference.** No such field exists yet:
     `user_preference/1` is the seam, and it answers `nil`. Adding
     `User.preferred_language_locale_id` is an explicit host schema change,
     made when someone needs it, not something this module presumes.
  2. **Their organization's default:** `Organization.languagelocale_id` →
     `Reference.LanguageLocale.code`, read once per request by
     `organization_locale/1`.
  3. **`Accept-Language`**, in quality order. It is last because it is the only
     signal a JSON:API call carries before a preference is stored.
  4. **`"en"`**, the source language of every catalog.

  `resolve/1` is that rule as a pure function over the sources;
  `AshEnterpriseWeb.Plugs.PutLocale` gathers them for a request and
  `AshEnterpriseWeb.LiveLocale` carries the answer into a LiveView.

  ## Two spellings of one locale

  Sources speak BCP 47 (`fr-CA`); Gettext names catalog directories with an
  underscore (`fr_CA`). A code is validated as BCP 47 first, as a string and
  without creating an atom, so an `Accept-Language` header cannot grow the
  atom table. It is mapped to a Gettext locale only here, at this boundary,
  and only onto a locale that has a catalog (`known_locales/0`): `fr-CA` is
  `fr_CA` when that catalog exists, else `fr`, else nothing. Everything
  downstream — the `:locale` assign, `Gettext.put_locale/2`, the A2UI and ACP
  boundaries — holds the Gettext form; `html_lang/1` turns it back into BCP 47
  for `<html lang>`.

  ## Does it query?

  `organization_locale/1` is one read, made by the plug once per request after
  `AshEnterpriseWeb.Plugs.LoadActorContext` has resolved the tenant. Nothing
  here runs inside a policy check.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Reference.LanguageLocale

  @backend AshEnterpriseWeb.Gettext
  @default "en"

  # BCP 47 (RFC 5646), the subset a UI locale uses: a 2-3 letter language,
  # an optional 4-letter script, an optional region (2 letters or 3 digits),
  # and any variants. Extensions and private use are refused: no catalog is
  # keyed on them.
  @tag ~r/\A[a-z]{2,3}(?:-[a-z]{4})?(?:-(?:[a-z]{2}|[0-9]{3}))?(?:-(?:[a-z0-9]{5,8}|[0-9][a-z0-9]{3}))*\z/i

  # Longer than any tag a catalog is keyed on; a guard before the regex.
  @max_tag_bytes 35

  # A header past this is not a browser's: read only its start.
  @max_header_bytes 1_024
  @max_header_entries 20

  @typedoc ~s(A Gettext locale with a catalog, e.g. `"fr"` or `"fr_CA"`.)
  @type gettext_locale :: String.t()

  @typedoc "The sources `resolve/1` chooses between, each optional."
  @type sources :: [
          user: String.t() | nil,
          organization: String.t() | nil,
          accept_language: String.t() | nil
        ]

  @doc "The locale every catalog is written in, and the last fallback."
  @spec default() :: gettext_locale()
  def default, do: @default

  @doc "The Gettext backend host copy is translated through."
  @spec backend() :: module()
  def backend, do: @backend

  @doc "The Gettext locales that have a catalog, the default among them."
  @spec known_locales() :: [gettext_locale()]
  def known_locales, do: Enum.uniq([@default | Gettext.known_locales(@backend)])

  @doc """
  The locale for a request, by the precedence in the moduledoc.

      iex> AshEnterpriseWeb.Locale.resolve(organization: "fr-CA", accept_language: "en")
      "fr"
      iex> AshEnterpriseWeb.Locale.resolve(accept_language: "xx-YY, fr;q=0.5")
      "fr"
      iex> AshEnterpriseWeb.Locale.resolve([])
      "en"
  """
  @spec resolve(sources()) :: gettext_locale()
  def resolve(sources) do
    known = known_locales()

    with nil <- negotiate(sources[:user], known),
         nil <- negotiate(sources[:organization], known),
         nil <- sources[:accept_language] |> accept_language() |> first_known(known) do
      @default
    end
  end

  @doc """
  `value` when it is a Gettext locale with a catalog, else `nil`. For a locale
  that comes back from somewhere it was stored (a LiveView session), which is
  trusted no further than this.
  """
  @spec known(term()) :: gettext_locale() | nil
  def known(value) when is_binary(value), do: if(value in known_locales(), do: value)
  def known(_value), do: nil

  @doc """
  `code` as a canonical BCP 47 tag (`fr-CA`), or `:error`. Pure string work:
  no atom is created whatever the input.
  """
  @spec parse_tag(term()) :: {:ok, String.t()} | :error
  def parse_tag(code) when is_binary(code) and byte_size(code) <= @max_tag_bytes do
    code = String.trim(code)

    if Regex.match?(@tag, code) do
      {:ok, code |> String.split("-") |> canonical_case() |> Enum.join("-")}
    else
      :error
    end
  end

  def parse_tag(_code), do: :error

  @doc """
  The Gettext locale with a catalog that `code` (BCP 47) maps to, or `nil`:
  the most specific first, so `fr-CA` is `fr_CA` if that catalog exists, then
  `fr`.
  """
  @spec negotiate(term(), [gettext_locale()]) :: gettext_locale() | nil
  def negotiate(code, known \\ known_locales()) do
    case parse_tag(code) do
      {:ok, tag} -> tag |> candidates() |> Enum.find(&(&1 in known))
      :error -> nil
    end
  end

  @doc """
  The language ranges of an `Accept-Language` header, best first. Entries
  with `q=0`, wildcards and malformed entries are dropped; equal weights keep
  the header's order.
  """
  @spec accept_language(term()) :: [String.t()]
  def accept_language(header) when is_binary(header) do
    header
    |> binary_part(0, min(byte_size(header), @max_header_bytes))
    |> String.split(",", trim: true)
    |> Enum.take(@max_header_entries)
    |> Enum.with_index()
    |> Enum.flat_map(&weighted/1)
    |> Enum.sort_by(fn {_tag, q, index} -> {-q, index} end)
    |> Enum.map(fn {tag, _q, _index} -> tag end)
  end

  def accept_language(_header), do: []

  @doc """
  The person's own locale preference: the seam for precedence step 1.

  `nil` for everyone today. There is no preference field on
  `AshEnterprise.Accounts.User`, and ADR 0060 leaves adding one
  (`preferred_language_locale_id`) to an explicit schema change. When it
  lands, this reads it off the actor the request already holds — no query.
  """
  @spec user_preference(term()) :: String.t() | nil
  def user_preference(_actor), do: nil

  @doc """
  The BCP 47 code of `organization_id`'s default locale, or `nil`. One query.

  Read without authorization: it resolves the language the organization's own
  people see their pages in, and returns a reference code, not a record. The
  actor's organization id comes from their `ActorContext`, so the read cannot
  reach another tenant's choice.
  """
  @spec organization_locale(Ash.UUID.t() | nil) :: String.t() | nil
  def organization_locale(nil), do: nil

  def organization_locale(organization_id) do
    LanguageLocale
    |> Ash.Query.filter(
      exists(Organization, id == ^organization_id and languagelocale_id == parent(id))
    )
    |> Ash.Query.select([:code])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %LanguageLocale{code: code}} -> code
      _none_or_error -> nil
    end
  end

  @doc """
  `locale` (a Gettext locale) as the BCP 47 tag `<html lang>` wants:
  `fr_CA` is `fr-CA`. Anything without a catalog is the default.
  """
  @spec html_lang(term()) :: String.t()
  def html_lang(locale) do
    (known(locale) || @default) |> String.replace("_", "-")
  end

  # -- helpers -----------------------------------------------------------------

  defp first_known(tags, known), do: Enum.find_value(tags, &negotiate(&1, known))

  defp weighted({entry, index}) do
    [range | params] = entry |> String.split(";") |> Enum.map(&String.trim/1)
    q = quality(params)

    if q > 0 and range != "*", do: [{range, q, index}], else: []
  end

  # A missing qvalue is 1; one that is not a number in 0..1 drops the entry
  # rather than being guessed at.
  defp quality(params) do
    case Enum.find(params, &String.starts_with?(&1, "q=")) do
      nil ->
        1.0

      "q=" <> value ->
        case Float.parse(String.trim(value)) do
          {q, ""} when q >= 0 and q <= 1 -> q
          _invalid -> 0.0
        end
    end
  end

  # `fr-ca` → `fr-CA`, `zh-hant-tw` → `zh-Hant-TW`: language lower, script
  # title, region upper, variants lower.
  defp canonical_case([language | rest]) do
    [String.downcase(language) | Enum.map(rest, &subtag_case/1)]
  end

  defp subtag_case(subtag) do
    cond do
      byte_size(subtag) == 4 and Regex.match?(~r/\A[a-z]{4}\z/i, subtag) ->
        String.capitalize(subtag)

      byte_size(subtag) == 2 ->
        String.upcase(subtag)

      true ->
        String.downcase(subtag)
    end
  end

  # `fr-CA` → ["fr_CA", "fr"]; `zh-Hant-TW` → ["zh_Hant_TW", "zh_Hant", "zh"].
  defp candidates(tag) do
    subtags = String.split(tag, "-")

    length(subtags)..1//-1
    |> Enum.map(fn n -> subtags |> Enum.take(n) |> Enum.join("_") end)
  end
end
