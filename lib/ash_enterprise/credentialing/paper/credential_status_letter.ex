defmodule AshEnterprise.Credentialing.Paper.CredentialStatusLetter do
  @moduledoc """
  The `credential_status_letter` document kind (`AshEnterprise.Documents.Paper.Kind`):
  the clinic writes to a clinician about the status of one of their credentials —
  the clinic, the clinician, which credential, its status and its expiry date.

  Issue one with

      AshEnterprise.Documents.issue_paper_run(
        "credential_status_letter",
        %{"credential_id" => credential.id},
        "Credential status",
        actor: person,
        tenant: organization_id
      )

  once the tenant has bound the kind (`AshEnterprise.Documents.bind_paper/4`).

  | Callback | Here |
  |---|---|
  | `key/0` | `"credential_status_letter"` |
  | `schema/0` | `__MODULE__.Schema` |
  | `default_theme/0` | `"carlito"` |
  | `clause_keys/0` | none: the letter carries no clause yet |
  | `decision_inputs/1` | none, as there is no clause table to feed |
  | `locale/1` | the tenant's default locale (`Organization.languagelocale_id`), as a kernel locale |
  | `requirement/0` | none: nothing is asked before the letter renders |
  | `source/2` | the `Credential`, its `Clinician` and their `Clinic`, read as the actor |
  | `scope/1` | empty: with no requirement, no answer is ever recorded |
  | `valid_until/1` | nil, for the same reason |
  | `sealing_scope/2` | the clinician's own erasure scope, read as the actor |

  ## The subject

  `%{"credential_id" => uuid}` (string or atom key). Nothing else the caller passes
  reaches the letter: `source/2` reads the credential through
  `AshEnterprise.Credentialing.get_credential/2` **as the actor**, loading its
  clinician and their clinic through those resources' own policies, so a person who
  may not read the credential, or its clinician, gets `{:error, reason}` and no run
  row. The credential's number is a secured column and is never read: the letter
  does not print it.

  ## Sealed under the clinician's scope

  The letter is about the clinician, so what it said is theirs:
  `sealing_scope/2` reads the credential's clinician as the actor, through the
  same policies `source/2` reads through, and names the clinician's own erasure
  scope (`erasure_scope_id`, opened at registration or by
  `AshEnterprise.Credentialing.open_clinician_erasure_scope/2`). The requester
  still owns the run. Shredding the clinician's scope erases the letter's
  payload, facts and key, and its bytes unless a run in a living scope shares
  them; shredding the requester's scope leaves it. A clinician with no scope,
  or a scope already shredded, refuses the issue
  (`AshEnterprise.Documents.Paper.SealingScope`).

  ## The locale

  The letter is written in the tenant's default language: the organization's
  `languagelocale_id`, as the BCP 47 code of its `AshEnterprise.Reference.LanguageLocale`,
  mapped onto a locale the kernel formats (`:fr` for any French code, `:en` for
  English). An organization that names no locale, or one the kernel does not format,
  gets `:en`, the language every catalog is written in. `locale/1` receives only the
  subject, so it finds the tenant through the credential the subject names; the issue
  calls it after `source/2` has read that credential as the actor, so it never
  answers for a credential the actor could not read.
  """

  use AshEnterprise.Documents.Paper.Kind

  require Ash.Query

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.Credential
  alias AshEnterprise.Documents.Paper.Kind
  alias AshEnterprise.Reference.LanguageLocale

  @default_locale :en

  @kinds %{
    en: %{licence: "Licence", certification: "Certification"},
    fr: %{licence: "Permis d'exercice", certification: "Certification"}
  }

  @statuses %{
    en: %{pending: "Pending activation", active: "Active"},
    fr: %{pending: "En attente d'activation", active: "Actif"}
  }

  @impl Kind
  def key, do: "credential_status_letter"

  @impl Kind
  def schema, do: __MODULE__.Schema

  @impl Kind
  def default_theme, do: "carlito"

  @impl Kind
  def clause_keys, do: []

  @impl Kind
  def decision_inputs(%AshPaper.Payload{}), do: %{}

  @impl Kind
  def locale(subject) do
    with {:ok, id} <- credential_id(Kind.arg(subject, :credential_id)),
         {:ok, organization_id} <- organization_of(id) do
      organization_locale(organization_id)
    else
      _unknown -> @default_locale
    end
  end

  @impl Kind
  def requirement, do: nil

  @impl Kind
  def source(subject, opts) do
    with {:ok, id} <- credential_id(Kind.arg(subject, :credential_id)),
         {:ok, credential} <- read(id, opts),
         {:ok, clinician} <- readable(credential.clinician, :clinician),
         {:ok, clinic} <- readable(clinician.clinic, :clinic) do
      {:ok, build(credential, clinician, clinic, organization_locale(credential.organization_id))}
    end
  end

  @impl Kind
  def sealing_scope(subject, opts) do
    with {:ok, id} <- credential_id(Kind.arg(subject, :credential_id)),
         {:ok, credential} <- read(id, opts),
         {:ok, clinician} <- readable(credential.clinician, :clinician) do
      case clinician.erasure_scope_id do
        scope_id when is_binary(scope_id) -> {:ok, scope_id}
        nil -> {:error, {:no_erasure_scope, :clinician}}
      end
    end
  end

  @impl Kind
  def scope(%AshPaper.Payload{}), do: %{}

  @impl Kind
  def valid_until(_scope), do: nil

  @doc """
  The source map for a credential, its clinician and their clinic in `locale`
  (`:en` or `:fr`): what `source/2` returns for those rows.
  """
  @spec build(map(), map(), map(), :en | :fr) :: map()
  def build(credential, clinician, clinic, locale) do
    %{
      clinic: clinic.name,
      clinician: full_name(clinician),
      credential: @kinds |> Map.fetch!(locale) |> Map.fetch!(credential.kind),
      status: @statuses |> Map.fetch!(locale) |> Map.fetch!(credential.status),
      expires_on: credential.expires_on
    }
  end

  defp credential_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:invalid_subject, :credential_id}}
    end
  end

  defp credential_id(_value), do: {:error, {:invalid_subject, :credential_id}}

  # The credential as the actor, its clinician and clinic loaded through their own
  # policies. A credential the actor may not read is not found, never a guess.
  defp read(id, opts) do
    opts = opts |> Keyword.take([:actor, :tenant]) |> Keyword.put(:load, clinician: [:clinic])

    case Credentialing.get_credential(id, opts) do
      {:ok, credential} -> {:ok, credential}
      {:error, error} -> {:error, {:not_readable, :credential, not_found_or(error)}}
    end
  end

  defp not_found_or(%Ash.Error.Invalid{errors: errors}) do
    if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)), do: :not_found, else: :invalid
  end

  defp not_found_or(%Ash.Error.Forbidden{}), do: :forbidden
  defp not_found_or(_error), do: :unknown

  # A related row the actor's policies withhold loads as nil: the letter is refused,
  # it does not print a blank in its place.
  defp readable(nil, name), do: {:error, {:not_readable, name, :forbidden}}
  defp readable(%Ash.NotLoaded{}, name), do: {:error, {:not_readable, name, :not_loaded}}
  defp readable(%Ash.ForbiddenField{}, name), do: {:error, {:not_readable, name, :forbidden}}
  defp readable(row, _name), do: {:ok, row}

  defp full_name(%{first_name: first, last_name: last}) do
    [first, last]
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> Enum.join(" ")
  end

  # The tenant of the credential the subject names. Read without authorization on
  # purpose: it answers which organization's language the letter is written in, and
  # returns an id, not a record (see the moduledoc on when it is called).
  defp organization_of(id) do
    Credential
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:organization_id])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Credential{organization_id: organization_id}} -> {:ok, organization_id}
      _none_or_error -> :error
    end
  end

  defp organization_locale(organization_id) do
    LanguageLocale
    |> Ash.Query.filter(
      exists(Organization, id == ^organization_id and languagelocale_id == parent(id))
    )
    |> Ash.Query.select([:code])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %LanguageLocale{code: code}} when is_binary(code) -> kernel_locale(code)
      _none_or_error -> @default_locale
    end
  end

  # A BCP 47 code onto a locale `AshPaper.Format` formats: the language subtag
  # decides, the region does not.
  defp kernel_locale(code) do
    case code |> String.downcase() |> String.split(["-", "_"], parts: 2) do
      ["fr" | _region] -> :fr
      _other -> @default_locale
    end
  end
end
