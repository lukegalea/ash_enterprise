defmodule AshEnterprise.Governance.DataFlows do
  @moduledoc """
  The register of egress paths: every way this application sends data to a
  recipient outside its own database, with what it sends and what governs it.

  Declared, not discovered. A row is a person's statement, so a path nobody
  wrote down is not in the register; `undeclared_modules/1` is the check that
  keeps the register from silently falling behind the code.

  ## What a row says

    * `:recipient_class` -- who receives it, by class only: a model provider, a
      self-hosted OAuth broker, a lineage collector, a mail provider. A
      deployment's actual vendors are its owner's to record; this register is
      the design-time half.
    * `:data_classes` -- what the path can carry, drawn from `data_classes/0`.
    * `:gate` -- what stops the path from sending when it should not, as
      `%{name: ..., enforced_by: Module}` where the module is the code that
      enforces it, or the atom `:none` when nothing does. `:none` requires a
      `:known_gap` saying why. A row never names a gate that does not govern
      the path it describes.
    * `:known_gap` -- what the gate does not cover, in prose.
    * `:modules` -- the modules that hold the egress code, so the coverage
      check can tell a covered file from a stranger.

  ## The coverage check is a grep

  `undeclared_modules/1` reads `lib/` for egress primitives (see
  `primitives/0`) and reports modules that hold one without appearing in any
  row. It is honest about what it is: a text scan with a list of known
  shapes. A new HTTP client shape (`:gun`, a raw socket, a library not in the
  list) passes unseen until the list grows. Operations declared through
  `AshOperations` are the exception: they are enumerated from the DSL
  (`operation_rows/0`), not from text.

  ## Looks-personal exceptions

  `looks_personal_exceptions/0` lists the attributes whose names match the
  inventory's personal-data heuristic but that are deliberately neither
  `sensitive?` nor sealed, each with the reason. It lives here because it is a
  statement about what leaves the database in the clear as much as about the
  schema. `AshEnterprise.Governance.DataInventory` consumes it.
  """

  @data_classes ~w(
    account_identity
    personal_data
    tenant_business_content
    model_prompts
    credentials_reference
    operational_metadata
    structural_names
    audit_events
    repository_text
    none
  )a

  # The shapes of egress code `undeclared_modules/1` looks for, as
  # {label, regex}. Matched against `lib/` source with comments and doc
  # strings removed.
  @primitives [
    {"Req request",
     ~r/\bReq\.(get!?|post!?|put!?|patch!?|delete!?|request!?|new|run!?|head!?)\b/},
    {"direct ReqLLM call",
     ~r/\bReqLLM\.(stream_text|generate_text|generate_object|stream_object|embed|evaluate)!?\b/},
    {"guarded model call", ~r/\bModels\.call\(/},
    {"model client option", ~r/\breq_llm:\s*[\w.]+/},
    {"AshAi prompt actions", ~r/\bimport AshAi\.Actions\b|\bAshAi\.ToolLoop\b/},
    {"judgment model capture", ~r/\bModelCapture\.evaluate\b/},
    {"Swoosh delivery", ~r/\bSwoosh\.Mailer\b|\bMailer\.deliver!?\(/},
    {"Finch", ~r/\bFinch\.[a-z_]+\(/},
    {":httpc", ~r/:httpc\.[a-z_]+\(/},
    {"HTTPoison", ~r/\bHTTPoison\.[a-z_]+\(/},
    {":hackney", ~r/:hackney\.[a-z_]+\(/},
    {"AshOperations resource",
     ~r/\buse AshOperations(\.Http)?(?![.\w])|extensions:\s*\[[^\]]*AshOperations/},
    {"OpenLineage transport",
     ~r/\bAshOpenLineage\.Transport\.(Req\.)?(send|dispatch)\b|\bAshOpenLineage\.(emit|fail)\b/}
  ]

  @rows [
    %{
      id: :integration_provider_proxy,
      name: "Provider API calls through the self-hosted OAuth broker",
      recipient_class: :integration_provider_api,
      data_classes: [:tenant_business_content, :personal_data, :credentials_reference],
      modules: [AshEnterprise.Integration.Nango.Proxy],
      gate: :none,
      known_gap:
        "The proxy checks that a linked account exists for the call, not the tenant's sub_processor_opt_in; " <>
          "what it sends is whatever the calling action or sync puts in the request. Authorization is the " <>
          "calling action's own policies and the tenant's link to the provider.",
      notes:
        "Credentials never travel in the request body: the broker injects the provider token. Telemetry carries structural names only."
    },
    %{
      id: :model_calls_guarded,
      name: "Model calls through the guarded client",
      recipient_class: :model_provider,
      data_classes: [:model_prompts, :tenant_business_content, :personal_data],
      modules: [
        AshEnterprise.AI.Models,
        AshEnterprise.AI.Models.GuardedReqLLM,
        AshEnterprise.AI.RequestClassifier,
        AshEnterprise.Canonical.Commitments.ModelExtractor,
        AshEnterprise.SystemOne.QuestionProposal.Transport
      ],
      gate: %{
        name:
          "Deployment-wide in-zone flow guard (REQUIRE_IN_ZONE_MODELS) plus the paste guard, and a call record for every call",
        enforced_by: AshEnterprise.AI.Models
      },
      known_gap:
        "The tenant's recorded sub_processor_opt_in is not consulted on this path: with the flow guard off, a " <>
          "hosted model is called for any tenant. The opt-in is enforced on the judgment path " <>
          "(model_calls_judgment), not here.",
      notes:
        "The call record holds caller, profile, model, residency and counts, never a prompt or an output."
    },
    %{
      id: :model_calls_judgment,
      name: "Judgment evaluations through the judgment model wire",
      recipient_class: :model_provider,
      data_classes: [:model_prompts, :tenant_business_content],
      modules: [
        AshEnterprise.SystemOne,
        AshEnterprise.SystemOne.DecisionWire,
        AshEnterprise.Licences.Rungs,
        AshEnterprise.Standards.Standing,
        AshEnterprise.Quality.Grader
      ],
      gate: %{
        name:
          "Residency policy: a sub-processor instrument is refused unless the tenant recorded an opt-in, and refused for everyone under the flow guard",
        enforced_by: AshEnterprise.Zones.ResidencyPolicy
      },
      known_gap: nil,
      notes: "Unknown tenants and unknown residency classes are refused."
    },
    %{
      id: :assistant_agent_runtime,
      name: "Assistant and agent runs",
      recipient_class: :model_provider,
      data_classes: [:model_prompts, :tenant_business_content, :personal_data],
      modules: [AshEnterprise.Execution.AgentRuntime],
      gate: %{
        name:
          "Only the in-zone model profile runs: any other profile is refused before a call is built",
        enforced_by: AshEnterprise.Execution.AgentRuntime
      },
      known_gap:
        "An in-zone refusal needs the operator's in-zone profile to be configured; the tenant's " <>
          "sub_processor_opt_in plays no part, because the path never reaches a sub-processor.",
      notes: nil
    },
    %{
      id: :design_time_translation,
      name: "Design-time catalogue translation (mix l10n.generate)",
      recipient_class: :model_provider,
      data_classes: [:repository_text],
      modules: [AshEnterprise.L10n.Translator.ReqLLM],
      gate: :none,
      known_gap:
        "Calls the model client directly, outside the guarded client and its call record. It sends only catalogue " <>
          "strings and a glossary from this repository, and is run by a person at a terminal, never by the application or CI.",
      notes: nil
    },
    %{
      id: :lineage_collector,
      name: "OpenLineage run events",
      recipient_class: :lineage_collector,
      data_classes: [:structural_names],
      modules: [
        AshEnterprise.Lineage,
        AshEnterprise.Lineage.Transport,
        AshEnterprise.Planning.CheckPipeline
      ],
      gate: %{
        name:
          "Off unless an HTTP collector is configured; events carry table-level names only, never actor, tenant or values",
        enforced_by: AshEnterprise.Lineage.Transport
      },
      known_gap: nil,
      notes:
        "A failed post is logged and dropped; the audit log, not the collector, is the record."
    },
    %{
      id: :outbound_mail,
      name: "Account mail (confirmation and password reset)",
      recipient_class: :mail_provider,
      data_classes: [:account_identity, :credentials_reference],
      modules: [
        AshEnterprise.Mailer,
        AshEnterprise.Accounts.User.Senders.SendNewUserConfirmationEmail,
        AshEnterprise.Accounts.User.Senders.SendPasswordResetEmail
      ],
      gate: :none,
      known_gap:
        "No tenant-level gate. A message goes to the address of the user the action is for, and carries a " <>
          "single-use token link. Which mail provider receives it is a deployment choice (default: local mailbox).",
      notes: nil
    },
    %{
      id: :standards_runtime_probe,
      name: "Standards check: model runtime version probe",
      recipient_class: :in_zone_model_runtime,
      data_classes: [:none],
      modules: [AshEnterprise.Standards.StandingWorker],
      gate: %{
        name:
          "Off unless the standing job is enabled; the target is the configured in-zone profile's own host",
        enforced_by: AshEnterprise.Standards.StandingWorker
      },
      known_gap: nil,
      notes: "A GET of the runtime's version. No tenant data."
    },
    %{
      id: :observability_exporter,
      name: "OpenTelemetry trace export",
      recipient_class: :observability_collector,
      data_classes: [:structural_names, :operational_metadata],
      modules: [AshEnterprise.Telemetry.GenAI.ContentFreeAdapter],
      gate: %{
        name:
          "No exporter runs unless OTEL_EXPORTER_OTLP_ENDPOINT is set; model-call spans carry no prompt or output content",
        enforced_by: AshEnterprise.Telemetry.GenAI.ContentFreeAdapter
      },
      known_gap: nil,
      notes: "Configured in config/runtime.exs; there is no Elixir call site to scan."
    },
    %{
      id: :mdm_egress_export,
      name: "Golden-record export to a customer's system",
      recipient_class: :tenant_customer_system,
      data_classes: [:personal_data, :tenant_business_content],
      modules: [AshEnterprise.Mdm.Export],
      gate: %{
        name:
          "The egress grant (a read grant on the egress resource), the tenant's active egress mapping, public attributes only",
        enforced_by: AshEnterprise.Mdm.Export
      },
      known_gap: nil,
      notes:
        "Produces rows for the tenant's own use; this module sends nothing over the network itself."
    },
    %{
      id: :audit_package_export,
      name: "Audit package for an auditor",
      recipient_class: :auditor,
      data_classes: [:audit_events, :structural_names],
      modules: [AshEnterprise.Audit.Export],
      gate: %{
        name:
          "Reads run under the exporting person's actor and tenant, so what the export holds is what that person's grants reach",
        enforced_by: AshEnterprise.Audit.Export
      },
      known_gap: nil,
      notes:
        "A directory of files written by a mix task; there is no export as the system and none across tenants."
    }
  ]

  @doc "The vocabulary a row's `:data_classes` draws from."
  @spec data_classes() :: [atom()]
  def data_classes, do: @data_classes

  @doc "The egress shapes the coverage scan looks for, as `{label, regex}`."
  @spec primitives() :: [{String.t(), Regex.t()}]
  def primitives, do: @primitives

  @doc "The declared rows (not the operation rows derived from DSL)."
  @spec declared_rows() :: [map()]
  def declared_rows, do: @rows

  @doc """
  One row per operation declared through `AshOperations` on a resource in the
  configured domains, read from the DSL. An operation that `discloses?` is
  gated by the resource's disclosure gate; one that does not carries
  `gate: :none` and says what that means.
  """
  @spec operation_rows() :: [map()]
  def operation_rows do
    for resource <- domain_resources(),
        AshOperations in Spark.extensions(resource),
        operation <- AshOperations.Info.operations(resource) do
      provider = AshOperations.Info.provider(resource)
      gate_module = AshOperations.Info.disclosure_gate(resource)

      base = %{
        id: :"operation_#{provider}_#{operation.name}",
        name:
          "#{provider}: #{String.upcase(to_string(operation.method))} #{operation.path} (#{operation.name})",
        recipient_class: :third_party_api,
        modules: Enum.reject([resource, AshOperations.Info.transport(resource)], &is_nil/1),
        operation: %{
          resource: inspect(resource),
          provider: to_string(provider),
          name: to_string(operation.name),
          method: to_string(operation.method),
          path: operation.path,
          discloses: operation.discloses?
        },
        notes: nil
      }

      if operation.discloses? and gate_module do
        Map.merge(base, %{
          data_classes: [:personal_data, :credentials_reference],
          gate: %{
            name:
              "Disclosure gate: refuses the send unless the tenant, the readable disclosure reference and the residency policy allow it",
            enforced_by: gate_module
          },
          known_gap: nil
        })
      else
        Map.merge(base, %{
          data_classes: [:credentials_reference],
          gate: :none,
          known_gap:
            if(operation.discloses?,
              do: "Declared as disclosing but the resource names no disclosure gate.",
              else:
                "Declared non-disclosing: it sends provider-side identifiers and paging parameters only, so no disclosure gate runs."
            )
        })
      end
    end
    |> Enum.sort_by(& &1.id)
  end

  @doc "Declared rows followed by the derived operation rows."
  @spec all() :: [map()]
  def all, do: @rows ++ operation_rows()

  @doc """
  Attributes whose names match the inventory's personal-data heuristic that are
  deliberately neither `sensitive?` nor sealed, each with the reason. Keys are
  `{resource_module, attribute}`.
  """
  @spec looks_personal_exceptions() :: %{{module(), atom()} => String.t()}
  def looks_personal_exceptions do
    computed =
      "Computed, never stored: the assistant's lookup builds it on request, as the asking person, behind the zone gate."

    legacy_twin =
      "The twin of a legacy table this application does not own, so it mirrors the source's columns as they are, in the clear. Masking or sealing is decided at cutover, not by the twin."

    legacy_view =
      "A read model over a legacy table in a strangler phase: the value is what the legacy source holds, in the clear. Masking or sealing is decided at cutover, not by the read model."

    %{
      {AshEnterprise.Accounts.User, :email} =>
        "The login identity. It is the credential's public half, must be queryable for sign-in and uniqueness, and cannot be sealed.",
      {AshEnterprise.Accounts.ProjectedUser, :email} => legacy_view,
      {AshEnterprise.Legacy.User, :email} => legacy_view,
      {AshEnterprise.Legacy.Twins.Users, :email} => legacy_twin,
      {AshEnterprise.Legacy.Twins.Users, :first_name} => legacy_twin,
      {AshEnterprise.Legacy.Twins.Users, :last_name} => legacy_twin,
      {AshEnterprise.Assistant.Lookup.Person, :email} => computed,
      {AshEnterprise.Assistant.Lookup.Duplicate, :existing_email} => computed,
      {AshEnterprise.Assistant.Lookup.Duplicate, :incoming_email} => computed,
      {AshEnterprise.Assistant.Lookup.Duplicate, :merge_keeps_email_of} => computed
    }
  end

  @doc """
  Modules under `root`/lib that contain an egress primitive and appear in no
  row of `rows` (default: `all/0`). Returns `[%{module: String.t(), file: String.t(), primitive: String.t()}]`.

  A text scan, with the limits described in the moduledoc.
  """
  @spec undeclared_modules(keyword()) :: [map()]
  def undeclared_modules(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    rows = Keyword.get(opts, :rows, all())

    covered =
      rows
      |> Enum.flat_map(& &1.modules)
      |> MapSet.new(&inspect/1)

    for file <- Path.wildcard(Path.join([root, "lib", "**", "*.ex"])) |> Enum.sort(),
        source = code_only(File.read!(file)),
        {label, regex} <- @primitives,
        Regex.match?(regex, source),
        modules = defined_modules(source),
        not Enum.any?(modules, &MapSet.member?(covered, &1)) do
      %{
        module: List.first(modules) || "(none)",
        file: Path.relative_to(file, root),
        primitive: label
      }
    end
    |> Enum.uniq_by(& &1.file)
  end

  @doc false
  def code_only(source) do
    source
    |> then(&Regex.replace(~r/@(moduledoc|doc|typedoc)\s+~?[a-zA-Z]?"""(.*?)"""/s, &1, ""))
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.join("\n")
  end

  defp defined_modules(source) do
    ~r/^\s*defmodule\s+([A-Z][\w.]*)\s+do/m
    |> Regex.scan(source)
    |> Enum.map(fn [_, name] -> name end)
  end

  defp domain_resources do
    :ash_enterprise
    |> Application.get_env(:ash_domains, [])
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
  end
end
