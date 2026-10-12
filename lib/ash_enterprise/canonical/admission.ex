defmodule AshEnterprise.Canonical.Admission do
  @moduledoc """
  Whether a message vertical's content may reach the canonical inbox yet — the
  zone gate's answer (ADR 0042), read the same way the projectors read it.

  Gmail and Slack land raw records under their linked account's erasure scope,
  but their projectors only write `Conversation`/`Message` rows for what a zone
  gate admits, and the default gates admit nothing until zone admission is on
  the SourceObject land path. Until then an empty inbox is not "no mail": it is
  mail deliberately held back. The Inbox and Slack surfaces say exactly that,
  and say nothing once the gate admits — they light up on their own.

  Reads configuration only; never the data, never the database.
  """

  alias AshEnterprise.Canonical.Projections
  alias AshEnterprise.Canonical.Projections.ZoneGate

  @type system :: :gmail | :slack

  @doc """
  `:admitted` when the vertical's projection has a real zone gate configured
  (`AshEnterprise.Canonical.Projections.ZoneGate.configured/1`), or
  `{:held, :zone_admission_not_wired}` while it keeps the template default,
  `ZoneGate.DenyAll`, which admits nothing. A configured gate may still refuse
  a particular account's records (its tags); that is "nothing admitted for
  this account yet", not "held".
  """
  @spec status(system()) :: :admitted | {:held, atom()}
  def status(system) do
    if ZoneGate.configured(projection(system)) == ZoneGate.DenyAll,
      do: {:held, :zone_admission_not_wired},
      else: :admitted
  end

  defp projection(:gmail), do: Projections.Gmail
  defp projection(:slack), do: Projections.Slack

  @doc "True when the vertical's content is held back by its zone gate."
  @spec held?(system()) :: boolean()
  def held?(system), do: status(system) != :admitted

  @doc """
  The sentence an empty inbox shows while the gate holds content back, or nil
  once it admits.
  """
  @spec notice(system()) :: String.t() | nil
  def notice(system) do
    case status(system) do
      :admitted ->
        nil

      {:held, _reason} ->
        "#{label(system)} content is held back until zone admission (ADR 0042) is built. " <>
          "Syncs still land it, sealed under the account's erasure scope, but the zone gate " <>
          "admits nothing into the canonical inbox yet — so this is empty on purpose, not " <>
          "because there is no mail. It fills in on its own once admission lands."
    end
  end

  @doc """
  What an *empty* inbox for `system` means, for an actor with or without an
  active linked account for it — three different situations that must not
  read alike:

    * the zone gate holds the vertical back (`notice/1`);
    * the gate admits, the actor has an account, and nothing has been
      admitted for it yet (the next sync's projection fills it);
    * the actor has no linked account for it at all.
  """
  @spec empty_message(system(), boolean()) :: String.t()
  def empty_message(system, linked?) do
    cond do
      notice = notice(system) ->
        notice

      linked? ->
        "Nothing has been admitted from your #{label(system)} account yet. " <>
          "Conversations appear here as syncs land and the zone gate admits them " <>
          "(an account whose tags the zone cannot hold stays out)."

      true ->
        "No #{label(system)} account is linked, so there is nothing to show. " <>
          "Link one and run a sync from Accounts & syncs."
    end
  end

  @doc "The Nango integration key the vertical's linked accounts carry."
  @spec integration(system()) :: String.t()
  def integration(:gmail), do: "google-mail"
  def integration(:slack), do: "slack"

  @doc "The vertical's display name."
  @spec label(system()) :: String.t()
  def label(:gmail), do: "Gmail"
  def label(:slack), do: "Slack"

  @doc "The `external_system` its canonical rows carry."
  @spec external_system(system()) :: String.t()
  def external_system(:gmail), do: "gmail"
  def external_system(:slack), do: AshEnterprise.Integration.Slack.Records.external_system()
end
