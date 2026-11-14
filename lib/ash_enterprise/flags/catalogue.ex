defmodule AshEnterprise.Flags.Catalogue do
  @moduledoc """
  The feature flags this build declares, and the ones the deployment has killed
  (ADR 0072).

  A flag is declared in configuration, as a key and what it turns on:

      config :ash_enterprise, AshEnterprise.Flags.Catalogue,
        flags: %{"reports.new_editor" => "The new report editor."}

  A key is a code path that exists in this build. A tenant decides who sees it with
  an `AshEnterprise.Flags.Flag` row; a row may only name a declared key, and a
  declared key with no row is off.

  ## Failing closed

  `AshEnterprise.Flags.enabled?/2` answers false, and logs, for a key the catalogue
  does not declare: a mistyped key at a call site hides the feature rather than
  showing it to everyone.

  ## The kill switch

  `FLAGS_OFF=key1,key2` in the environment (read by `config/runtime.exs` into
  `:killed`) turns those keys off everywhere, whatever any tenant's row says. It
  is the deployment's answer to a flagged feature misbehaving: one restart, no
  tenant's cooperation, and no row is rewritten, so removing the key from
  `FLAGS_OFF` restores what each tenant had chosen.
  """

  require Logger

  @doc "The declared flags: key to description."
  @spec flags() :: %{String.t() => String.t()}
  def flags, do: Keyword.get(config(), :flags, %{})

  @doc "The declared keys, sorted."
  @spec keys() :: [String.t()]
  def keys, do: flags() |> Map.keys() |> Enum.sort()

  @doc "Whether `key` is declared in this build."
  @spec declared?(term()) :: boolean()
  def declared?(key) when is_binary(key), do: Map.has_key?(flags(), key)
  def declared?(_key), do: false

  @doc "What the declared flag `key` turns on, or nil."
  @spec description(String.t()) :: String.t() | nil
  def description(key), do: Map.get(flags(), key)

  @doc "The keys the deployment has killed (`FLAGS_OFF`)."
  @spec killed() :: [String.t()]
  def killed, do: Keyword.get(config(), :killed, [])

  @doc "Whether the deployment has killed `key`."
  @spec killed?(String.t()) :: boolean()
  def killed?(key), do: key in killed()

  @doc """
  Whether `key` may be on at all in this deployment: declared, and not killed. An
  undeclared key is logged, since it is a call site naming a flag this build does
  not have.
  """
  @spec available?(term()) :: boolean()
  def available?(key) do
    cond do
      not declared?(key) ->
        Logger.warning("Feature flag #{inspect(key)} is not declared; it is off.")
        false

      killed?(key) ->
        false

      true ->
        true
    end
  end

  @doc "Parses a `FLAGS_OFF` value (`key1,key2`) into keys."
  @spec parse_killed(String.t() | nil) :: [String.t()]
  def parse_killed(nil), do: []

  def parse_killed(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp config, do: Application.get_env(:ash_enterprise, __MODULE__, [])
end
