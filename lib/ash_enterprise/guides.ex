defmodule AshEnterprise.Guides do
  @moduledoc """
  A journey's approved run as an in-app guide: A2UI 1.0 messages over the basic
  catalog (a `Column` of `Text` and `Image`), built from the journey's IR and the
  lock in `priv/journeys/`, never from a run in progress.

  `AshJourneys`' rule holds here as on the site pages (`mix ash_journeys.export`):
  a guide shows only what a passing run of the same journey version recorded. A
  journey whose approved run in the locale does not prove it now
  (`AshJourneys.Lock.verify/6`: none approved, a newer declaration or browser
  pin, approved files or a lock entry that are not what approval wrote, or text
  and labels that resolve differently than the run recorded) is not shown: the
  page says so, and the reason is logged.

  The page is the steps, numbered, each with its narration (every `ui/1` label in
  bold, in the reader's locale), its figures and its notes, then the outcome. The
  title and goal are the page header, from the guide's registry entry
  (`AshEnterprise.Surfaces.guides/0`).

  A figure is drawn at its own size, never wider than the column (the basic
  catalog's default Image: no variant), so a cropped dialog stays its size and a
  full-page capture fills the column, scaled down at phone width.

  Figures are served at `/app/guide/figures/<file_sha256>.png`, the digest the lock
  records for the approved file (`figure/1`), with masked regions painted the
  neutral colour the site pages use.

  Every message is checked against the vendored A2UI 1.0 schema before it is
  served (`AshEnterprise.Guides.Schema`).
  """

  use Gettext, backend: AshEnterpriseWeb.Gettext

  require Logger

  # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see Audit.Export).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  alias AshEnterprise.Guides.Schema
  alias AshJourneys.{Export, Info, L10n, Lock, Manifest, Raster}

  @catalog "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"
  @figures "/app/guide/figures/"

  @typedoc "A guide's journey: the module that declares it and its id."
  @type journey :: {module(), atom()}

  @doc """
  The guide's messages for the renderer (`AshA2ui.LiveRenderer`'s `:surface_fn`,
  whose `ui` is the journey), in `opts[:locale]`. A guide that cannot be shown is
  one message saying so.
  """
  @spec surface(journey(), keyword()) :: [map()]
  def surface({_module, id} = journey, opts) do
    case messages(journey, opts[:locale] || AshEnterpriseWeb.Locale.default()) do
      {:ok, messages} ->
        messages

      {:error, problems} ->
        Logger.warning("guide #{id} cannot be shown: #{Enum.join(problems, "; ")}")
        unavailable(id)
    end
  end

  @doc """
  The guide's messages in `locale` (the journey's first locale when it declares
  none for it), or every reason it cannot be shown.
  """
  @spec messages(journey(), String.t()) :: {:ok, [map()]} | {:error, [String.t()]}
  def messages({module, id}, locale) do
    with {:ok, %{ir: ir} = journey} <- declared(module, id),
         locale = if(locale in ir["locales"], do: locale, else: hd(ir["locales"])),
         {:ok, entry} <- approved(journey, locale),
         {:ok, components} <- components(module, ir, entry, locale) do
      messages = [create(id, components)]

      case Schema.validate(messages) do
        :ok -> {:ok, messages}
        {:error, reason} -> {:error, ["the guide breaks the A2UI 1.0 schema: #{reason}"]}
      end
    end
  end

  @doc """
  The PNG for the approved figure whose `file_sha256` is `digest`, with masked
  regions painted the neutral colour, or `:error` when the lock names no such
  figure or the file is not the one it approved.
  """
  # The path is the lock's (`figure_path/2`), never the caller's: a digest only
  # selects one of the files the lock approved.
  @sobelow_skip ["Traversal.FileModule"]
  @spec figure(String.t()) :: {:ok, binary()} | :error
  def figure(digest) do
    with {:ok, lock} <- Lock.read(root()),
         {:ok, path} <- figure_path(lock, digest),
         {:ok, bytes} <- File.read(path),
         ^digest <- sha256(bytes),
         {:ok, raster} <- Raster.decode(bytes) do
      painted = Raster.recolor(raster, Export.capture_mask_color(), Export.neutral_color())
      {:ok, if(painted == raster, do: bytes, else: Raster.encode(painted))}
    else
      _missing_or_altered -> :error
    end
  end

  # -- what the lock approved ------------------------------------------------------

  defp root, do: Application.app_dir(:ash_enterprise)

  defp declared(module, id) do
    with {:ok, declared} <- Lock.declared([module]) do
      case Map.fetch(declared, Atom.to_string(id)) do
        {:ok, journey} -> {:ok, journey}
        :error -> {:error, ["#{inspect(module)} declares no journey #{id}"]}
      end
    end
  end

  defp approved(%{ir: ir} = journey, locale) do
    with {:ok, lock} <- Lock.read(root()) do
      case Lock.verify(root(), lock, ir["id"], journey, locale) do
        {:ok, entry, _manifest} ->
          {:ok, entry}

        {:error, _refusal, reasons} ->
          {:error, Enum.map(reasons, &"#{ir["id"]} (#{locale}): #{&1}")}
      end
    end
  end

  # The lock's own record of where the approved file is: `digest` only selects it.
  defp figure_path(lock, digest) do
    found =
      for {id, locales} <- lock.journeys,
          {locale, entry} <- locales,
          {_key, %{file_sha256: ^digest} = figure} <- entry.figures,
          do: Path.join(Lock.approved_dir(root(), locale, id), figure.file)

    case found do
      [path | _same_bytes] -> {:ok, path}
      [] -> :error
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # -- the page --------------------------------------------------------------------

  defp components(module, ir, entry, locale) do
    backend = Info.gettext(module)
    registry = Info.surface_registry(module)
    text = &L10n.text(backend, &1, &2, locale)
    label = &L10n.label(&1, registry, backend, locale)

    steps =
      ir["steps"]
      |> Enum.with_index(1)
      |> Enum.map(fn {step, number} -> step(step, number, entry, text, label) end)

    with {:ok, steps} <- collect(steps),
         {:ok, outcome} <- text.(ir["outcome"], %{}) do
      body = List.flatten(steps) ++ [text_component("outcome", outcome)]
      root = %{"id" => "root", "component" => "Column", "children" => Enum.map(body, & &1["id"])}
      {:ok, [root | body]}
    end
  end

  defp step(step, number, entry, text, label) do
    name = step["name"]

    with {:ok, says} <-
           collect(for %{"type" => "say"} = say <- step["narration"], do: say(say, text, label)),
         {:ok, notes} <-
           collect(
             for %{"type" => "note"} = note <- step["narration"], do: text.(note["text"], %{})
           ) do
      alt = says |> hd() |> String.replace("**", "")

      figures =
        for %{"type" => "figure"} = figure <- step["body"] do
          file = Map.fetch!(entry.figures, Manifest.figure_key(name, figure["name"])).file_sha256

          %{
            "id" => "figure_#{name}_#{figure["name"]}",
            "component" => "Image",
            "url" => @figures <> file <> ".png",
            "description" => alt,
            "fit" => "contain"
          }
        end

      notes =
        notes
        |> Enum.with_index(1)
        |> Enum.map(fn {note, n} -> text_component("note_#{name}_#{n}", "> " <> note) end)

      {:ok, [text_component("step_#{name}", numbered(number, says)) | figures ++ notes]}
    end
  end

  defp say(%{"text" => msgid, "bindings" => bindings}, text, label) do
    labels =
      Enum.map(bindings, fn {name, binding} ->
        with {:ok, label} <- label.(binding),
             do: {:ok, {String.to_existing_atom(name), "**#{label}**"}}
      end)

    with {:ok, labels} <- collect(labels), do: text.(msgid, Map.new(labels))
  end

  # Component ids are UAX #31 identifiers, which the browser checks and the
  # schema does not: `step_<name>`, never `step-<name>`.

  # One Markdown list item numbered `number`, so a step keeps its number when
  # figures sit between steps.
  defp numbered(number, paragraphs) do
    marker = "#{number}. "
    indent = String.duplicate(" ", String.length(marker))
    marker <> Enum.join(paragraphs, "\n\n" <> indent)
  end

  defp text_component(id, text), do: %{"id" => id, "component" => "Text", "text" => text}

  defp create(id, components) do
    %{
      "version" => "1.0",
      "createSurface" => %{
        "surfaceId" => "guide-#{id}",
        "catalogId" => @catalog,
        "components" => components,
        "dataModel" => %{}
      }
    }
  end

  defp unavailable(id) do
    create(id, [
      %{"id" => "root", "component" => "Column", "children" => ["unavailable"]},
      text_component(
        "unavailable",
        dgettext("default", "This guide cannot be shown until a run of it is approved.")
      )
    ])
    |> List.wrap()
  end

  defp collect(results) do
    case Enum.flat_map(results, fn
           {:error, problems} -> problems
           {:ok, _value} -> []
         end) do
      [] -> {:ok, Enum.map(results, fn {:ok, value} -> value end)}
      problems -> {:error, problems}
    end
  end
end
