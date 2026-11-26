defmodule AshEnterprise.Provenance.Labels do
  @moduledoc """
  Who an act was associated with, named only as far as the reader may see
  (ADR 0078, section 6).

  A person is named by their email only when the reader may read that person's
  user record through its own read action; otherwise the answer says "a person"
  and never carries an identifier. A system actor is named by its name ("the
  nightly job did this" stays distinct from "not recorded"), and an automation
  principal as one.
  """

  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Accounts

  @doc """
  The label of the actor an audit event records: `{:ok, label}`, or
  `:not_recorded` when the event names nobody (no user id and no non-human
  actor in its metadata).
  """
  @spec agent_label(Ash.Resource.record(), AshEnterprise.Provenance.Explainer.ctx()) ::
          {:ok, String.t()} | :not_recorded
  def agent_label(event, ctx) do
    metadata = event.metadata || %{}

    cond do
      name = metadata["system_actor"] ->
        {:ok, dgettext("provenance", "the system (%{name})", name: name)}

      name = metadata["automation_principal"] ->
        {:ok, dgettext("provenance", "an automation principal (%{name})", name: name)}

      is_nil(event.user_id) ->
        :not_recorded

      true ->
        user_label(event.user_id, ctx)
    end
  end

  @doc """
  The label of a person by user id: their email when the reader may read the
  user record, "a person" when they may not, `:not_recorded` for no id.
  """
  @spec user_label(term(), AshEnterprise.Provenance.Explainer.ctx()) ::
          {:ok, String.t()} | :not_recorded
  def user_label(nil, _ctx), do: :not_recorded

  def user_label(user_id, ctx) do
    # The cache holds the raw result (`{:ok, label}` or `:not_recorded`), as
    # `RecordColumns` writes it, so one read of one person serves every step
    # that names them.
    case Map.fetch(ctx.cache, {:user, user_id}) do
      {:ok, remembered} ->
        remembered

      :error ->
        case Accounts.get_user(user_id, actor: ctx.actor, tenant: ctx.tenant) do
          {:ok, user} -> {:ok, to_string(user.email)}
          {:error, _not_readable} -> {:ok, dgettext("provenance", "a person")}
        end
    end
  end
end
