defmodule AshEnterprise.Execution.Release.Entries do
  @moduledoc """
  The entries of a release manifest (ADR 0058): in-toto `ResourceDescriptor`s
  (https://github.com/in-toto/attestation/blob/main/spec/v1/resource_descriptor.md), one
  for each thing a release names, with the digest it had when the manifest was resolved.

      %{
        "name" => "clinic.referral_triager",
        "uri" => "urn:ash-enterprise:agent:clinic.referral_triager:3",
        "digest" => %{"sha256" => "…"},
        "annotations" => %{"kind" => "agent", "id" => "…", "version" => 3}
      }

  The kinds, and what `resolve/3` pins for each `key`:

    * `process` and `decision`: the latest published definition the tenant is entitled to for
      the key (`AshEnterprise.Process.Resolver.latest/3`), by its content hash;
    * `agent` and `suite`: the latest published version in the tenant, by its content hash;
    * `tool`: the governed target named `key` (`Module.action`), by the digest of its
      declaration (`AshAgent.Invocation.Target.digest/1`);
    * `ruleset`: the compiled rules of the module named `key` (`AshRules`), by the bundle's
      content hash;
    * `judgment_question`: `"Resource/question"`, by the question's hash
      (`AshJudgments.Registry`);
    * `model_profile`: the profile the deployment serves, by a digest of its name and the
      model behind it.

  `check/2` asks whether an entry still holds: the thing it names exists, is still published
  where it has to be, and has the digest it had. A definition, agent or suite is looked up by
  the `id` the entry recorded, so a version published since does not fail a release that
  pinned the earlier one.
  """

  alias AshAgent.Digest
  alias AshAgent.Invocation.Target
  alias AshEnterprise.AI.Models
  alias AshEnterprise.Execution
  alias AshEnterprise.Process.Resolver
  alias AshEnterprise.Quality

  @kinds [
    :process,
    :decision,
    :ruleset,
    :agent,
    :judgment_question,
    :tool,
    :model_profile,
    :suite
  ]

  @typedoc "An entry, as stored: string keys throughout."
  @type t :: %{required(String.t()) => term()}

  @doc "The kinds an entry may be."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Resolves `key` of `kind` in `tenant` to an entry, or says why it cannot."
  @spec resolve(atom(), String.t(), Ash.UUID.t()) :: {:ok, t()} | {:error, String.t()}
  def resolve(kind, key, tenant) when kind in [:process, :decision] do
    with {:ok, definition} <- Resolver.latest(kind, key, tenant),
         :ok <- published(definition, kind, key) do
      {:ok, versioned_entry(kind, definition)}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, _reason} -> {:error, "#{kind} #{key} has no published definition"}
    end
  end

  def resolve(:agent, key, tenant) do
    case Execution.latest_published_agent_version(key,
           authorize?: false,
           tenant: tenant,
           not_found_error?: false
         ) do
      {:ok, %{} = version} -> {:ok, versioned_entry(:agent, version)}
      _none -> {:error, "agent #{key} has no published version"}
    end
  end

  def resolve(:suite, key, tenant) do
    case Quality.latest_published_suite(key,
           authorize?: false,
           tenant: tenant,
           not_found_error?: false
         ) do
      {:ok, %{} = suite} -> {:ok, versioned_entry(:suite, suite)}
      _none -> {:error, "suite #{key} has no published version"}
    end
  end

  def resolve(:tool, key, _tenant) do
    case Target.resolve(key) do
      {:ok, target} ->
        {:ok,
         descriptor(:tool, key, "urn:ash-enterprise:tool:#{key}", Target.digest(target), %{})}

      {:error, message} ->
        {:error, "tool #{key}: #{message}"}
    end
  end

  def resolve(:ruleset, key, _tenant) do
    with {:ok, module} <- module(key),
         {:ok, bundle} <- AshRules.Info.bundle(module) do
      hash = AshRules.Ir.Bundle.content_hash(bundle)
      {:ok, descriptor(:ruleset, key, "urn:ash-enterprise:ruleset:#{key}", hash, %{})}
    else
      _no_rules -> {:error, "ruleset #{key} is not a compiled rule set"}
    end
  end

  def resolve(:judgment_question, key, _tenant) do
    with [resource, question] <- String.split(key, "/", parts: 2),
         {:ok, module} <- module(resource),
         {:ok, name} <- existing_atom(question),
         hash when is_binary(hash) <- AshJudgments.Registry.Info.hash(module, name) do
      uri = "urn:ash-enterprise:judgment_question:#{key}"
      {:ok, descriptor(:judgment_question, key, uri, hash, %{})}
    else
      _none -> {:error, "judgment question #{key} is not declared (use Resource/question)"}
    end
  end

  def resolve(:model_profile, key, _tenant) do
    target = Models.resolve(Models.interpreter_spec())

    if target.profile == key do
      hash =
        Digest.sha256_hex(%{"profile" => key, "model" => target.label, "zone" => target.zone})

      uri = "urn:ash-enterprise:model_profile:#{key}"
      {:ok, descriptor(:model_profile, key, uri, hash, %{"residency" => target.residency})}
    else
      {:error, "model profile #{key} is not what this deployment serves (#{target.profile})"}
    end
  end

  @doc """
  Whether `entry` still holds in `tenant`: `:ok`, or `{:error, message}` saying what changed.
  """
  @spec check(t(), Ash.UUID.t()) :: :ok | {:error, String.t()}
  def check(%{"annotations" => %{"kind" => kind, "id" => id}} = entry, tenant)
      when kind in ["process", "decision", "agent", "suite"] and is_binary(id) do
    name = entry["name"]

    case fetch(String.to_existing_atom(kind), id, tenant) do
      {:ok, %{status: :published} = found} ->
        if hex(found.content_hash) == entry["digest"]["sha256"],
          do: :ok,
          else: {:error, "#{kind} #{name} is not the content the manifest pinned"}

      {:ok, %{status: status}} ->
        {:error, "#{kind} #{name} is #{status}, not published"}

      _missing ->
        {:error, "#{kind} #{name} no longer resolves"}
    end
  end

  def check(%{"annotations" => %{"kind" => kind}} = entry, tenant) do
    with {:ok, kind} <- existing_atom(kind),
         {:ok, again} <- resolve(kind, entry["name"], tenant) do
      if again["digest"] == entry["digest"],
        do: :ok,
        else: {:error, "#{kind} #{entry["name"]} has changed since the manifest was resolved"}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _other -> {:error, "an entry names a kind this build does not know"}
    end
  end

  @doc "The problems with `entries`, one message each; `[]` when every entry holds."
  @spec problems([t()], Ash.UUID.t()) :: [String.t()]
  def problems(entries, tenant) do
    for entry <- entries, {:error, message} <- [check(entry, tenant)], do: message
  end

  @doc "The entry of `kind` named `name` among `entries`, or nil."
  @spec find([t()], atom() | String.t(), String.t()) :: t() | nil
  def find(entries, kind, name) do
    kind = to_string(kind)
    Enum.find(entries, &(&1["annotations"]["kind"] == kind and &1["name"] == name))
  end

  # The same definition a tenant would be handed, wherever it lives: its own, or the
  # platform baseline it follows.
  defp fetch(kind, id, tenant) when kind in [:process, :decision],
    do: Resolver.definition(kind, id, tenant)

  defp fetch(:agent, id, tenant),
    do: Execution.get_agent_version(id, authorize?: false, tenant: tenant)

  defp fetch(:suite, id, tenant), do: Quality.get_suite(id, authorize?: false, tenant: tenant)

  defp published(%{status: :published}, _kind, _key), do: :ok

  defp published(%{status: status}, kind, key),
    do: {:error, "#{kind} #{key} is #{status}, not published"}

  defp versioned_entry(kind, %{key: key, version: version, id: id, content_hash: hash}) do
    descriptor(kind, key, "urn:ash-enterprise:#{kind}:#{key}:#{version}", hash, %{
      "id" => id,
      "version" => version
    })
  end

  defp descriptor(kind, name, uri, hash, annotations) do
    %{
      "name" => name,
      "uri" => uri,
      "digest" => %{"sha256" => hex(hash)},
      "annotations" => Map.put(annotations, "kind", to_string(kind))
    }
  end

  # A content hash is a SHA-256 in hex already; anything else is hashed, so the digest of
  # an entry is always one.
  defp hex(hash) when is_binary(hash) do
    if byte_size(hash) == 64 and String.match?(hash, ~r/\A[0-9a-f]+\z/),
      do: hash,
      else: Digest.sha256_hex(hash)
  end

  defp module(name) do
    case existing_atom("Elixir." <> name) do
      {:ok, module} -> if Code.ensure_loaded?(module), do: {:ok, module}, else: :error
      :error -> :error
    end
  end

  defp existing_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end
end
