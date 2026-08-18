defmodule Mix.Tasks.Cdm.Gen.Resource do
  @shortdoc "Generate an Ash resource from a resolved CDM/Dataverse entity"

  @moduledoc """
  Turns a resolved corpus entity into a starting-point Ash resource.

      mix cdm.gen.resource Currency --domain Reference --ownership organization_owned
      mix cdm.gen.resource TimeZoneDefinition --domain Reference --no-tenant
      mix cdm.gen.resource LanguageLocale --domain Reference --no-tenant

  Reads `priv/cdm/resolved/<entity>.json` (or `dataverse_<entity>.json`), which
  must already exist -- this task does not fetch or resolve anything, per
  `docs/manifesto/02-schema-commons.md`. Run the Python resolver first for an
  entity not yet vendored; see the `cdm-adopt` skill.

  ## What it does

    * Strips every attribute the platform base resource already supplies --
      ownership, provenance, lifecycle, tenancy, version. See
      `AshEnterprise.Platform.SystemAttributes`.
    * Maps the remaining attributes to Ash types, carrying required-ness,
      max length, and the source description across as documentation.
    * Writes `lib/ash_enterprise/<domain>/<entity>.ex` using
      `AshEnterprise.Platform.Resource`.
    * Creates the domain module if it does not exist yet, or adds a `resource`
      line to it if it does.
    * Registers a new domain in `config :ash_enterprise, ash_domains: [...]`.

  ## What it deliberately does not do

  It does not guess a `Lookup` attribute's target module, wire up
  relationships, add identities, or decide `ownership:` for a CDM entity that
  carries no Dataverse ownership metadata -- those are judgment calls the
  `cdm-adopt` skill calls "the corpus proposes, you dispose", not something to
  automate. A remaining `Lookup`/`Customer` attribute is emitted as a plain
  `:uuid` column with a note naming the unresolved target entity.

  ## Options

    * `--domain` (required) -- e.g. `Reference` or `AshEnterprise.Reference`.
    * `--ownership` -- `user_owned` | `business_owned` | `organization_owned` |
      `none`. Required when the entity has no scraped
      `dataverse.ownership_type` (true of every plain CDM entity) -- never
      guessed otherwise.
    * `--tenant` / `--no-tenant` -- defaults to `true`. Override to `false` for
      genuinely global reference data (time zones, locales); see
      `AshEnterprise.Platform.SystemAttributes`.
    * `--api-type` -- expose over JSON:API/GraphQL under this type. Omitted by
      default, matching the platform default of no public surface.
    * `--table` -- override the derived (pluralized) table name.
    * `--source` -- `cdm` (default) or `dataverse`, when an entity is resolved
      from both corpora (the JSON is otherwise identical in shape).
    * `--force` -- overwrite an existing resource file.
    * `--dry-run` -- print the resource source without writing anything.

  ## After running

      mix ash.codegen <descriptive_name>
      mix ash.migrate
      mix ash_enterprise.seed --privileges-only

  And, mandatorily: open the generated file and delete the columns you do not
  need. See `.claude/skills/cdm-adopt/`.
  """

  use Mix.Task

  @app_dir "lib/ash_enterprise"
  @resolved_dir "priv/cdm/resolved"
  @config_file "config/config.exs"

  # The CDM/Dataverse system columns the platform base resource already
  # supplies -- see AshEnterprise.Platform.SystemAttributes. Matched against
  # `source_name`, the raw lowercase Dataverse logical name, which is stable
  # across both corpora (unlike `field`, which formatting could in principle
  # diverge on).
  @skip_source_names ~w(
    createdon createdby createdonbehalfby
    modifiedon modifiedby modifiedonbehalfby
    overriddencreatedon importsequencenumber versionnumber
    statecode statuscode
    organizationid
    ownerid owneridtype owninguser owningbusinessunit owningteam
    entityimageid entityimage entityimage_timestamp entityimage_url
    timezoneruleversionnumber utcconversiontimezonecode
    traversedpath processid stageid
  )

  @ownership_map %{
    "UserOwned" => :user_owned,
    "User" => :user_owned,
    "BusinessOwned" => :business_owned,
    "BusinessUnit" => :business_owned,
    "OrganizationOwned" => :organization_owned,
    "Organization" => :organization_owned,
    "None" => :none
  }

  @switches [
    domain: :string,
    ownership: :string,
    tenant: :boolean,
    api_type: :string,
    table: :string,
    source: :string,
    force: :boolean,
    dry_run: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    arg =
      case args do
        [entity] -> entity
        _ -> Mix.raise("Usage: mix cdm.gen.resource EntityName --domain DomainModule")
      end

    domain_opt =
      opts[:domain] ||
        Mix.raise(
          "--domain is required, e.g. --domain Reference or --domain AshEnterprise.Reference"
        )

    {json_path, json} = load_resolved!(arg, opts[:source])

    entity = json["entity"] || Mix.raise("#{json_path} has no top-level \"entity\" field.")
    domain_module = normalize_domain(domain_opt)
    resource_module = Module.concat(domain_module, entity)

    ownership = resolve_ownership!(json, opts[:ownership], entity)
    tenant? = Keyword.get(opts, :tenant, true)
    table = opts[:table] || pluralize(json["table"] || Macro.underscore(entity))

    attributes = build_attributes(json)

    source =
      render_resource(%{
        module: resource_module,
        domain: domain_module,
        cdm_entity: entity,
        table: table,
        ownership: ownership,
        tenant?: tenant?,
        api_type: opts[:api_type],
        attributes: attributes,
        provenance: json["provenance"] || %{},
        json_path: json_path
      })

    if opts[:dry_run] do
      Mix.shell().info(source)
    else
      path = write_resource!(domain_module, entity, source, opts[:force])
      ensure_domain!(domain_module, resource_module)
      register_domain!(domain_module)

      Mix.shell().info("""

      Generated #{inspect(resource_module)} at #{path}, from #{json_path}.
      #{length(attributes)} attribute(s) carried over.

      Now, mandatorily:

        1. Open the file and delete the columns you do not need.
        2. mix ash.codegen <descriptive_name>
        3. mix ash.migrate
        4. mix ash_enterprise.seed --privileges-only
      """)
    end
  end

  # --- locating and reading the corpus -----------------------------------

  defp load_resolved!(entity, source_pref) do
    underscored = Macro.underscore(entity)

    candidates =
      case source_pref do
        "dataverse" -> ["dataverse_#{underscored}.json", "#{underscored}.json"]
        nil -> ["#{underscored}.json", "dataverse_#{underscored}.json"]
        "cdm" -> ["#{underscored}.json", "dataverse_#{underscored}.json"]
        other -> Mix.raise(~s|--source must be "cdm" or "dataverse", got #{inspect(other)}|)
      end

    path =
      Enum.find_value(candidates, fn file ->
        candidate = Path.join(@resolved_dir, file)
        if File.exists?(candidate), do: candidate
      end)

    path ||
      Mix.raise("""
      No resolved JSON for #{inspect(entity)} in #{@resolved_dir}/.
      Tried: #{Enum.join(candidates, ", ")}

      This entity has not been resolved yet -- this task only reads the
      committed corpus and never fetches anything. See the cdm-adopt skill:
      widen priv/cdm/tools/vendor.sh, then run resolve.py or dataverse_docs.py.
      """)

    json = path |> File.read!() |> Jason.decode!()
    {path, json}
  end

  # --- domain / ownership resolution --------------------------------------

  defp normalize_domain(domain) do
    if String.contains?(domain, ".") do
      Module.concat([domain])
    else
      Module.concat([AshEnterprise, domain])
    end
  end

  defp resolve_ownership!(json, nil, entity) do
    case get_in(json, ["dataverse", "ownership_type"]) do
      nil ->
        Mix.raise("""
        #{entity} has no scraped dataverse.ownership_type -- it was resolved
        from the plain CDM corpus, which carries no ownership information at
        all.

        Pass --ownership explicitly. Do not guess: see
        AshEnterprise.Platform.SystemAttributes for what each value means and
        docs/manifesto/02-schema-commons.md for why this is not inferred.
        """)

      scraped ->
        Map.get(@ownership_map, scraped) ||
          Mix.raise("Unrecognized dataverse.ownership_type #{inspect(scraped)} for #{entity}.")
    end
  end

  defp resolve_ownership!(_json, override, _entity)
       when override in ~w(user_owned business_owned organization_owned none) do
    String.to_existing_atom(override)
  end

  defp resolve_ownership!(_json, override, _entity) do
    Mix.raise(
      "--ownership must be one of user_owned/business_owned/organization_owned/none, got #{inspect(override)}"
    )
  end

  # --- attribute mapping ---------------------------------------------------

  defp build_attributes(json) do
    primary = primary_source_name(json)

    json["attributes"]
    |> List.wrap()
    |> Enum.reject(&skip?(&1, primary))
    |> Enum.map(&build_attribute/1)
  end

  defp primary_source_name(json) do
    case get_in(json, ["dataverse", "primary_id"]) do
      nil ->
        json["attributes"]
        |> List.wrap()
        |> Enum.find(& &1["is_primary_key"])
        |> case do
          nil -> nil
          attr -> attr["source_name"] || attr["field"]
        end

      primary_id ->
        primary_id
    end
  end

  defp skip?(attr, primary_source_name) do
    source_name = attr["source_name"] || attr["field"]

    source_name == primary_source_name or
      source_name in @skip_source_names or
      String.ends_with?(attr["field"] || "", "_display")
  end

  defp build_attribute(attr) do
    %{
      name: attr["field"],
      type: ash_type(attr),
      required?: attr["required_level"] in ~w(required applicationrequired systemrequired),
      max_length: attr["max_length"],
      description: description_for(attr)
    }
  end

  # The two source vocabularies, each mapped to the narrowest Ash type that does
  # not lose information. They are tables rather than `case` clauses because a
  # table is the thing they are -- and because a reader adding a CDM data format
  # should not have to read control flow to do it.
  #
  # `Money` becomes `:decimal` rather than `AshMoney`'s type on purpose: the CDM
  # carries the amount and the currency in separate columns, so pairing them is a
  # judgement about which currency column applies, and the generator does not
  # make judgements. `Lookup` and `Customer` become a bare `:uuid` for the same
  # reason -- see the unresolved-foreign-key note `description_for/1` attaches.
  @cdm_data_formats %{
    "STRING" => :string,
    "INT32" => :integer,
    "INT64" => :integer,
    "DECIMAL" => :decimal,
    "DOUBLE" => :float,
    "BOOLEAN" => :boolean,
    "DATE_TIME" => :utc_datetime_usec,
    "DATE" => :date,
    "TIME" => :time,
    "GUID" => :uuid
  }

  @dataverse_types %{
    "String" => :string,
    "Memo" => :string,
    "Integer" => :integer,
    "BigInt" => :integer,
    "Decimal" => :decimal,
    "Double" => :float,
    "Money" => :decimal,
    "Boolean" => :boolean,
    "DateTime" => :utc_datetime_usec,
    "Date" => :date,
    "Uniqueidentifier" => :uuid,
    "Lookup" => :uuid,
    "Customer" => :uuid,
    "Picklist" => :integer
  }

  # Both fall back to `:string` rather than raising. The corpus is third-party
  # and pinned, so an unrecognised format is a gap in these tables rather than
  # bad data -- and the generated resource is meant to be edited before it ships.
  defp ash_type(%{"data_format" => fmt}) when is_binary(fmt),
    do: Map.get(@cdm_data_formats, fmt, :string)

  defp ash_type(%{"dataverse_type" => type}) when is_binary(type),
    do: Map.get(@dataverse_types, type, :string)

  defp ash_type(_attr), do: :string

  defp description_for(attr) do
    base = attr["description"] || attr["display_name"]

    note =
      case {attr["dataverse_type"], attr["targets"]} do
        {type, [_ | _] = targets} when type in ["Lookup", "Customer"] ->
          " Unresolved foreign key -- targets #{Enum.join(targets, ", ")}. Wire up a real relationship, or delete this column."

        _ ->
          nil
      end

    [base, note]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("")
    |> String.trim()
  end

  # --- rendering -------------------------------------------------------------

  defp render_resource(ctx) do
    attrs_src = Enum.map_join(ctx.attributes, "\n\n", &render_attribute/1)

    provenance = ctx.provenance

    """
    defmodule #{inspect(ctx.module)} do
      @moduledoc \"\"\"
      Generated by `mix cdm.gen.resource` from `#{ctx.json_path}`.

      Source: #{ctx.cdm_entity} (#{provenance["source"]}, #{provenance["document"]}).

      This is a starting point, not a finished resource. Per
      `docs/manifesto/02-schema-commons.md`, delete the columns you do not need
      and add the actions, calculations and relationships that are genuinely
      yours before this ships.
      \"\"\"

      use AshEnterprise.Platform.Resource,
        domain: #{inspect(ctx.domain)},
        ownership: #{inspect(ctx.ownership)},
        tenant?: #{ctx.tenant?}#{api_type_line(ctx.api_type)},
        cdm_entity: #{inspect(ctx.cdm_entity)}

      postgres do
        table #{inspect(ctx.table)}
        repo AshEnterprise.Repo
      end

      attributes do
        uuid_primary_key :id

    #{attrs_src}
      end

      actions do
        defaults [:read, :destroy]
        default_accept [#{accept_list(ctx.attributes)}]

        create :create do
          primary? true
        end

        update :update do
          primary? true
        end
      end

      code_interface do
        define :create
        define :read
        define :update
        define :destroy
      end
    end
    """
  end

  defp api_type_line(nil), do: ""
  defp api_type_line(type), do: ",\n    api_type: :#{type}"

  defp accept_list(attributes) do
    Enum.map_join(attributes, ", ", &":#{&1.name}")
  end

  defp render_attribute(attr) do
    lines =
      [
        attr.required? && "allow_nil? false",
        "public? true",
        attr.max_length && "constraints max_length: #{attr.max_length}",
        present?(attr.description) && "description #{inspect(attr.description)}"
      ]
      |> Enum.filter(& &1)
      |> Enum.map_join("\n", &("    " <> &1))

    """
      attribute :#{attr.name}, #{inspect(attr.type)} do
    #{lines}
      end
    """
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  # --- writing files -----------------------------------------------------

  defp write_resource!(domain_module, entity, source, force?) do
    domain_short = domain_module |> Module.split() |> List.last()
    dir = Path.join(@app_dir, Macro.underscore(domain_short))
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{Macro.underscore(entity)}.ex")

    if File.exists?(path) and not force? do
      Mix.raise("#{path} already exists. Pass --force to overwrite.")
    end

    File.write!(path, source)
    Mix.Task.run("format", [path])
    path
  end

  defp ensure_domain!(domain_module, resource_module) do
    domain_short = domain_module |> Module.split() |> List.last()
    path = Path.join(@app_dir, "#{Macro.underscore(domain_short)}.ex")

    if File.exists?(path) do
      add_resource_to_domain!(path, resource_module)
    else
      File.write!(path, render_domain(domain_module, resource_module))
    end

    Mix.Task.run("format", [path])
  end

  defp render_domain(domain_module, resource_module) do
    """
    defmodule #{inspect(domain_module)} do
      @moduledoc \"\"\"
      Scaffolded by `mix cdm.gen.resource`. Replace this with a real domain
      moduledoc once the domain holds more than a generated starting point --
      see the other domains in lib/ash_enterprise/ for the expected shape
      (what is exposed over the public APIs and why, what is deliberately not).
      \"\"\"

      use Ash.Domain,
        otp_app: :ash_enterprise,
        extensions: [AshAdmin.Domain]

      admin do
        show? true
      end

      resources do
        resource #{inspect(resource_module)}
      end
    end
    """
  end

  defp add_resource_to_domain!(path, resource_module) do
    content = File.read!(path)
    line = "resource #{inspect(resource_module)}"

    if String.contains?(content, line) do
      :ok
    else
      lines = String.split(content, "\n")
      resources_index = Enum.find_index(lines, &(String.trim(&1) == "resources do"))

      resources_index ||
        Mix.raise("Could not find a `resources do` block in #{path}. Add `#{line}` by hand.")

      indent = leading_whitespace(Enum.at(lines, resources_index))

      close_index =
        lines
        |> Enum.drop(resources_index + 1)
        |> Enum.find_index(&(String.trim_trailing(&1) == indent <> "end"))

      close_index ||
        Mix.raise("Could not find the end of the `resources do` block in #{path}.")

      absolute_close_index = resources_index + 1 + close_index
      new_lines = List.insert_at(lines, absolute_close_index, "  #{indent}#{line}")

      File.write!(path, Enum.join(new_lines, "\n"))
    end
  end

  defp leading_whitespace(line) do
    [ws | _] = Regex.run(~r/^(\s*)/, line)
    ws
  end

  defp register_domain!(domain_module) do
    content = File.read!(@config_file)
    entry = inspect(domain_module)

    if String.contains?(content, entry) do
      :ok
    else
      updated =
        Regex.replace(
          ~r/ash_domains: \[([^\]]*)\]/,
          content,
          fn _, list -> "ash_domains: [#{String.trim(list)}, #{entry}]" end,
          global: false
        )

      if updated == content do
        Mix.raise("Could not find `ash_domains: [...]` in #{@config_file}. Add #{entry} by hand.")
      end

      File.write!(@config_file, updated)
      Mix.Task.run("format", [@config_file])
    end
  end

  # --- misc ----------------------------------------------------------------

  defp pluralize(word) do
    cond do
      String.ends_with?(word, "y") and byte_size(word) > 1 and
          String.at(word, -2) not in ~w(a e i o u) ->
        String.slice(word, 0..-2//1) <> "ies"

      String.ends_with?(word, ["s", "x", "z", "ch", "sh"]) ->
        word <> "es"

      true ->
        word <> "s"
    end
  end
end
