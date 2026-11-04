defmodule Mix.Tasks.L10n.Generate do
  @shortdoc "Fills a locale's empty catalog messages through a model, for review"

  @moduledoc """
  Machine-translates the untranslated messages of a locale's Gettext
  catalogs, at design time (ADR 0060, section 3). A person runs it; the pull
  request that commits its output is the review.

      mix gettext.extract --merge                  # catalogs up to date first
      mix gettext.merge priv/gettext --locale fr   # once, to create fr's catalogs
      mix l10n.generate --locale fr                # fill what is empty
      mix l10n.generate --locale fr --domain auth --dry-run

  ## Options

    * `--locale` (required) — the Gettext locale, e.g. `fr` or `fr_CA`.
    * `--domain` — one catalog (default: every `.po` the locale has).
    * `--batch-size` — messages per model call, 1..50 (default 20).
    * `--model` — a ReqLLM model spec (default: `AshEnterprise.AI.model/0`).
    * `--glossary` — a JSON object of `"source term": "translation"`
      (default: `priv/l10n/glossary.<locale>.json` when it exists).
    * `--dry-run` — validate and report, write nothing.

  Only empty messages are sent and only validated answers are written
  (`AshEnterprise.L10n.Generator`); a refused batch leaves every catalog
  untouched and prints why. Running it twice changes nothing the second time.
  No model is called at compile time, on read, in a test or in CI.

  ## Why not `gettext_translator`

  Evaluated first, as ADR 0060 asks (0.9.3, 2026-11-04), and not adopted:

    * it depends on LangChain (`>= 0.8.0`, unbounded), a second LLM client
      beside ReqLLM, which this platform standardizes on;
    * it translates one message per call, with no batching, glossary or
      source context;
    * it writes the model's text without checking it: no placeholder,
      plural-count, empty-string or invented-msgid validation, and a failed
      call crashes the run (`{:ok, _} =`) after earlier files were written;
    * it reorders messages (translated first) and appends a timestamped
      changelog, so its output is not idempotent;
    * most of the package is a LiveDashboard page and a GitHub/GitLab
      pull-request client, neither of which a design-time task needs.

  What it does do — Expo for PO I/O, a model per locale — is the small part,
  so this task is written here on Expo and ReqLLM. It becomes a standalone
  package (named without an `ash_` prefix) only when a second repository
  wants it.

  The translator is `AshEnterprise.L10n.Translator.ReqLLM` unless the
  application environment names another under
  `config :ash_enterprise, AshEnterprise.L10n, translator: Module`, which is
  how this task's tests run it with a fake.
  """

  use Mix.Task

  alias AshEnterprise.L10n.Generator

  @switches [
    locale: :string,
    domain: :string,
    batch_size: :integer,
    model: :string,
    glossary: :string,
    dry_run: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)
    locale = opts[:locale] || Mix.raise("--locale is required, e.g. --locale fr")

    unless Regex.match?(~r/\A[a-z]{2,3}(_[A-Za-z0-9]{2,8})*\z/, locale) do
      Mix.raise("--locale must be a Gettext locale like fr or fr_CA, got #{inspect(locale)}")
    end

    # Config only: the model call needs ReqLLM and its HTTP client, not the
    # application, its database or its queues.
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:req_llm)

    root = Path.join(gettext_priv(), locale)
    files = catalogs(root, opts[:domain])
    glossary = glossary(opts[:glossary], locale)

    generator_opts = [
      locale: locale,
      translator: translator(),
      translator_opts: Keyword.take(opts, [:model]),
      glossary: glossary,
      batch_size: Keyword.get(opts, :batch_size, 20)
    ]

    # Every catalog is translated and validated before any is written.
    results =
      Enum.map(files, fn path ->
        domain = Path.basename(path, ".po")
        content = File.read!(path)

        case Generator.generate(content, Keyword.put(generator_opts, :domain, domain)) do
          {:ok, output, stats} -> {path, content, output, stats}
          {:error, problems} -> refuse(path, problems)
        end
      end)

    for {path, content, output, stats} <- results do
      Mix.shell().info("#{path}: #{stats.translated} translated in #{stats.batches} batches")
      if output != content and !opts[:dry_run], do: File.write!(path, output)
    end
  end

  defp refuse(path, problems) do
    lines =
      Enum.map_join(problems, "\n", fn {msgid, reason} -> "  #{inspect(msgid)}: #{reason}" end)

    Mix.raise("#{path}: the translator's answer was refused, nothing written.\n" <> lines)
  end

  defp catalogs(root, domain) do
    dir = Path.join(root, "LC_MESSAGES")

    files =
      case domain do
        nil -> dir |> Path.join("*.po") |> Path.wildcard() |> Enum.sort()
        domain -> [Path.join(dir, domain <> ".po")]
      end

    case Enum.filter(files, &File.regular?/1) do
      [] ->
        Mix.raise(
          "No catalog under #{dir}. Create it first: mix gettext.merge priv/gettext --locale " <>
            Path.basename(root)
        )

      files ->
        files
    end
  end

  defp glossary(nil, locale) do
    default = Path.join(["priv", "l10n", "glossary.#{locale}.json"])
    if File.exists?(default), do: read_glossary(default), else: %{}
  end

  defp glossary(path, _locale), do: read_glossary(path)

  defp read_glossary(path) do
    case path |> File.read!() |> Jason.decode() do
      {:ok, %{} = glossary} ->
        Map.reject(glossary, fn {key, _value} -> String.starts_with?(key, "_") end)

      _other ->
        Mix.raise("#{path} is not a JSON object of term => translation")
    end
  end

  defp translator do
    :ash_enterprise
    |> Application.get_env(AshEnterprise.L10n, [])
    |> Keyword.get(:translator, AshEnterprise.L10n.Translator.ReqLLM)
  end

  defp gettext_priv, do: Path.join("priv", "gettext")
end
