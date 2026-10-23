defmodule AshEnterprise.Finance.Tiller.SyncError do
  @moduledoc """
  A Tiller sync step that stopped for a reason that is not a provider-edge
  failure (those stay `AshEnterprise.Integration.ProxyError`s).

  | `reason` | Meaning |
  |---|---|
  | `:no_sheet` | the linked account has no Tiller sheet configured (`AshEnterprise.Finance.TillerSource`) |
  | `:zone_refused` | the account's zone tags are not admissible in the finance zone, or no finance zone is declared; `detail` is the admission reason |
  | `:landing_refused` | the account's erasure scope could not be opened (`:scoped_landing_not_wired`, `:scope_shredded`, `:scope_unavailable`) |
  | `:mappings_not_installed` | a finance mapping has no active version (`AshEnterprise.Finance.install!/0`) |
  | `:unexpected_layout` | a tab lacks a header the sync needs; `detail` is the stream |
  | `:empty_tab` | a tab came back with no rows where rows had landed before; nothing is removed on its word |
  | `:currency_undeclared` | an account in the sheet has no declared currency and there is no default; `detail` is how many accounts |
  | `:unreadable_record` | a landed version could not be opened with the scope's key |
  | `:record_failed` | landing a row or recording its events failed; the row is retried next step |

  Fields are structural only — never a payload, an amount, a payee or an
  account name — because job errors are persisted by Oban.
  """

  use Splode.Error, fields: [:reason, :detail], class: :unknown

  @impl true
  def message(%__MODULE__{reason: reason, detail: nil}), do: "tiller sync: #{reason}"

  def message(%__MODULE__{reason: reason, detail: detail}),
    do: "tiller sync: #{reason} (#{detail})"

  @doc "The `SyncError` inside an action's error, or nil."
  def unwrap(%__MODULE__{} = error), do: error
  def unwrap(%{errors: errors}) when is_list(errors), do: Enum.find_value(errors, &unwrap/1)
  def unwrap(%{error: error}), do: unwrap(error)
  def unwrap(_), do: nil
end
