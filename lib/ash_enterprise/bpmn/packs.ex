defmodule AshEnterprise.Bpmn.Packs do
  @moduledoc """
  Recipe packs: versioned data under `priv/packs/<name>/` that a tenant installs as drafts.

  A pack is a directory holding a `pack.json` manifest and the process documents its recipes
  start. Installing one (`AshEnterprise.Bpmn.Subscription.install_pack/2`, or
  `mix ash_enterprise.packs.install`) creates, in one tenant and as the person installing it,
  a draft process definition for each process and a draft subscription for each recipe.

  **A pack cannot make itself live.** Nothing it installs is published, enabled or granted:
  a person publishes the process and then the recipe, from the designer and `/app/triggers`,
  and only then does an event start anything. So the manifest accepts no status, no
  `enabled`, and no authority but `human_tasks_only`:

    * `causing_person` is refused, because it makes the writer of an event the authority for
      what the process then does, and only the setup path, for one reviewed key, chooses it
      (`AshEnterprise.Bpmn.Subscription.Validations.AuthoritySelectable`);
    * `standing_grant` is refused, because a standing grant is the act of the person who
      publishes the recipe (`publish_granted`), never something a draft arrives with.

  Installing is idempotent: a process or recipe whose key the tenant already has, in any
  status or version, is left as it is and reported as existing, so a re-run creates nothing.

  ## The manifest

      {
        "name": "soc2_cc6_3",
        "version": 1,
        "title": "...",
        "controls": ["CC6.3"],
        "processes": [{"key": "...", "name": "...", "file": "review_role_change.bpmn"}],
        "recipes": [{"key": "...", "match_resource": "AshEnterprise.Security.UserRole",
                     "match_action_type": "create", "process_key": "...",
                     "authority": "human_tasks_only"}]
      }

  A recipe may also carry `match_action` and `guard_feel`; any other field is refused, so a
  manifest cannot set what the installer does not mean to install. `controls` names the
  framework criteria the pack's processes support. It is documentation for now: mapping
  controls to evidence (an OSCAL component definition) is later work.

  A pack may also carry a `templates` list. The installer ignores it; it is read by
  `AshEnterprise.Compliance.TemplateMap`, which checks the `soc2` pack's map of
  `ash_compliance`'s operator process templates to its recipes, to recipes and processes
  that already exist, or to the reason a template has no event trigger.
  """

  require Ash.Query

  alias AshEnterprise.Bpmn.{Definition, Subscription}

  @name ~r/\A[a-z0-9_]+\z/
  @file_name ~r/\A[a-z0-9_]+\.bpmn\z/
  @recipe_fields ~w(key match_resource match_action match_action_type guard_feel process_key authority)
  @action_types %{
    "create" => :create,
    "update" => :update,
    "destroy" => :destroy,
    "action" => :action
  }

  @typedoc "A pack read from disk and checked, ready to install."
  @type t :: %{
          name: String.t(),
          version: pos_integer(),
          processes: [%{key: String.t(), name: String.t(), xml: String.t()}],
          recipes: [%{key: String.t(), attrs: map()}]
        }

  @doc "The directory packs are read from: this application's `priv/packs`."
  @spec root() :: Path.t()
  def root, do: Application.app_dir(:ash_enterprise, "priv/packs")

  @doc "The packs under `root`: every directory with a `pack.json`, by name."
  @spec names(Path.t()) :: [String.t()]
  def names(root \\ root()) do
    root
    |> Path.join("*/pack.json")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
    |> Enum.filter(&Regex.match?(@name, &1))
    |> Enum.sort()
  end

  @doc """
  Reads and checks the pack `name` under `root`: `{:ok, pack}`, or `{:error, message}`
  naming what is wrong. Only a name `names/1` lists is read, so a name is never a path.
  """
  @spec load(String.t(), Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(name, root \\ root()) do
    with :ok <- known(name, root),
         dir = Path.join(root, name),
         {:ok, manifest} <- manifest(dir),
         {:ok, processes} <- processes(manifest, dir),
         {:ok, recipes} <- recipes(manifest) do
      {:ok,
       %{
         name: name,
         version: manifest["version"] || 1,
         processes: processes,
         recipes: recipes
       }}
    end
  end

  @doc """
  Installs `pack` into the tenant in `opts` as the actor in `opts`: a draft definition per
  process and a draft subscription per recipe, skipping every key the tenant already has.
  Returns what it did, by key: `%{pack:, processes: %{key => :created | :existing},
  recipes: %{key => :created | :existing}}`.

  Every read and write runs with the caller's actor, so the policies that decide whether
  they may create definitions and subscriptions decide the install.
  """
  @spec install(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def install(pack, opts) do
    with {:ok, processes} <- each(pack.processes, &install_process(&1, opts)),
         {:ok, recipes} <- each(pack.recipes, &install_recipe(&1, opts)) do
      {:ok, %{pack: pack.name, processes: Map.new(processes), recipes: Map.new(recipes)}}
    end
  end

  # ── reading ──────────────────────────────────────────────────────────────

  defp known(name, root) when is_binary(name) do
    if name in names(root) do
      :ok
    else
      {:error, "no pack named #{inspect(name)}; the packs are #{Enum.join(names(root), ", ")}"}
    end
  end

  defp known(name, _root), do: {:error, "no pack named #{inspect(name)}"}

  # `dir` is a directory `names/1` listed under this application's priv/packs, never a path
  # from input (`known/2` refuses any other name), so Sobelow's low-confidence Traversal
  # finding here is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp manifest(dir) do
    with {:ok, body} <- File.read(Path.join(dir, "pack.json")),
         {:ok, %{} = manifest} <- Jason.decode(body) do
      {:ok, manifest}
    else
      {:ok, _not_an_object} -> {:error, "pack.json is not a JSON object"}
      {:error, %Jason.DecodeError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, "could not read pack.json: #{inspect(reason)}"}
    end
  end

  defp processes(manifest, dir) do
    manifest
    |> Map.get("processes", [])
    |> each(&process(&1, dir))
    |> case do
      {:ok, by_key} -> {:ok, Enum.map(by_key, fn {_key, process} -> process end)}
      error -> error
    end
  end

  # `file` is checked by `file_name/1` to be a bare `.bpmn` name inside the pack's own
  # directory, which `manifest/1` explains; the Traversal finding is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp process(%{"key" => key, "file" => file} = entry, dir) when is_binary(key) do
    with :ok <- file_name(file),
         {:ok, xml} <- File.read(Path.join(dir, file)) do
      {:ok, {key, %{key: key, name: entry["name"] || key, xml: xml}}}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "process #{key}: could not read #{file}: #{inspect(reason)}"}
    end
  end

  defp process(entry, _dir), do: {:error, "a process needs a key and a file: #{inspect(entry)}"}

  defp file_name(file) when is_binary(file) do
    if Regex.match?(@file_name, file),
      do: :ok,
      else: {:error, "process file #{inspect(file)} must be a .bpmn file in the pack's directory"}
  end

  defp file_name(file), do: {:error, "process file #{inspect(file)} is not a name"}

  defp recipes(manifest) do
    manifest
    |> Map.get("recipes", [])
    |> each(&recipe/1)
    |> case do
      {:ok, by_key} -> {:ok, Enum.map(by_key, fn {key, attrs} -> %{key: key, attrs: attrs} end)}
      error -> error
    end
  end

  defp recipe(%{"key" => key} = entry) when is_binary(key) do
    with :ok <- known_fields(key, entry),
         :ok <- authority(key, Map.get(entry, "authority", "human_tasks_only")),
         {:ok, action_type} <- action_type(key, entry["match_action_type"]),
         {:ok, action} <- match_action(key, entry["match_action"]) do
      attrs =
        %{
          key: key,
          match_resource: entry["match_resource"],
          match_action: action,
          match_action_type: action_type,
          guard_feel: entry["guard_feel"],
          process_key: entry["process_key"]
        }
        |> Map.reject(fn {_field, value} -> is_nil(value) end)

      {:ok, {key, attrs}}
    end
  end

  defp recipe(entry), do: {:error, "a recipe needs a key: #{inspect(entry)}"}

  defp known_fields(key, entry) do
    case Map.keys(entry) -- @recipe_fields do
      [] ->
        :ok

      unknown ->
        {:error,
         "recipe #{key}: a pack does not set #{Enum.join(unknown, ", ")}; a recipe is " <>
           "installed as a draft and a person publishes it"}
    end
  end

  defp authority(_key, "human_tasks_only"), do: :ok

  defp authority(key, "causing_person") do
    {:error,
     "recipe #{key}: a pack cannot run a recipe as the causing person; that is chosen only " <>
       "by the setup path, for one reviewed key"}
  end

  defp authority(key, "standing_grant") do
    {:error,
     "recipe #{key}: a pack cannot carry a standing grant; the person who publishes the " <>
       "recipe grants it, with publish_granted"}
  end

  defp authority(key, other),
    do: {:error, "recipe #{key}: unknown authority #{inspect(other)}"}

  defp action_type(_key, nil), do: {:ok, nil}

  defp action_type(key, type) do
    case Map.fetch(@action_types, type) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "recipe #{key}: unknown match_action_type #{inspect(type)}"}
    end
  end

  # An action name the application does not already know cannot be one it audits, so a name
  # that is not an existing atom is refused rather than minted.
  defp match_action(_key, nil), do: {:ok, nil}

  defp match_action(key, name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, "recipe #{key}: unknown match_action #{inspect(name)}"}
  end

  defp match_action(key, name),
    do: {:error, "recipe #{key}: match_action #{inspect(name)} is not a name"}

  # ── installing ───────────────────────────────────────────────────────────

  defp install_process(process, opts) do
    if exists?(Definition, process.key, opts) do
      {:ok, {process.key, :existing}}
    else
      with {:ok, definition} <-
             Definition.create(%{key: process.key, name: process.name, xml: process.xml}, opts) do
        compiled(definition)
      end
    end
  end

  defp compiled(%{errors: errors, key: key}) when errors in [nil, []], do: {:ok, {key, :created}}

  defp compiled(%{errors: errors, key: key}),
    do: {:error, "process #{key} does not compile: #{inspect(errors)}"}

  defp install_recipe(%{key: key, attrs: attrs}, opts) do
    if exists?(Subscription, key, opts) do
      {:ok, {key, :existing}}
    else
      with {:ok, _draft} <- Subscription.create(attrs, opts), do: {:ok, {key, :created}}
    end
  end

  defp exists?(resource, key, opts) do
    resource
    |> Ash.Query.filter(key == ^key)
    |> Ash.Query.limit(1)
    |> Ash.read!(opts)
    |> Enum.any?()
  end

  # Runs `fun` over `items`, stopping at the first error; `{:ok, [{key, value}]}` in order.
  defp each(items, fun) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  defp each(other, _fun), do: {:error, "expected a list, got #{inspect(other)}"}
end
