defmodule AshEnterprise.Credentialing.CredentialStatusLetterTest do
  @moduledoc """
  The neutral document kind, end to end: a SYNTHETIC clinic issues a letter to a
  clinician about one credential. The letter is read from the clinic's own rows as
  the person issuing it, in the tenant's language, and sealed under the clinician's
  own erasure scope: shredding it erases what the letter said and, unless a run in a
  surviving scope shares them, its bytes, while shredding the requester's scope leaves
  it. A clinician whose scope is shredded or missing cannot be written about; the
  stored snapshot names nobody; and a stored run re-renders from its frozen payload
  to the same digest. Every refusal is checked as a refusal, never as an empty letter.
  """

  use AshEnterprise.DataCase, async: true

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{Clinic, Clinician, Credential}
  alias AshEnterprise.Credentialing.Paper.CredentialStatusLetter
  alias AshEnterprise.Documents
  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Documents.Paper.Error, as: PaperError
  alias AshEnterprise.Documents.Paper.Impact.Rerender
  alias AshEnterprise.Documents.Paper.SealingScope
  alias AshEnterprise.Documents.PaperRun
  alias AshEnterprise.Erasure
  alias AshEnterprise.Execution.Changes.SealingScope, as: RequesterScope
  alias AshEnterprise.Reference.LanguageLocale

  alias __MODULE__.Stubs

  @moduletag :evidence

  defmodule Stubs.NoScope do
    @moduledoc "A kind's callbacks without `sealing_scope/2`."
    def key, do: "stub_no_scope"
  end

  defmodule Stubs.Fixed do
    @moduledoc "A `sealing_scope/2` that answers whatever the subject tells it to."
    def sealing_scope(%{"scope" => id}, _opts), do: {:ok, id}
    def sealing_scope(%{"error" => reason}, _opts), do: {:error, reason}
    def sealing_scope(%{"return" => returned}, _opts), do: returned
  end

  @kind "credential_status_letter"
  @title "Credential status"

  @readers [
    {Credential, :read, :global},
    {Clinician, :read, :global},
    {Clinic, :read, :global}
  ]

  setup do
    admin = tenant!()
    opts = [actor: admin.actor, tenant: admin.tenant]
    n = System.unique_integer([:positive])

    clinic = Credentialing.register_clinic!("Synthetic Clinic #{n}", opts)

    clinician =
      Credentialing.register_clinician!(
        %{
          first_name: "Synthetic",
          last_name: "Clinician#{n}",
          job_title: "Physiotherapist",
          clinic_id: clinic.id
        },
        opts
      )

    credential =
      Credentialing.record_credential!(
        %{
          kind: :licence,
          number: "SYN-#{n}",
          expires_on: ~D[2027-03-31],
          clinician_id: clinician.id
        },
        opts
      )

    bind(admin)

    {:ok, admin: admin, clinic: clinic, clinician: clinician, credential: credential}
  end

  describe "issue" do
    test "the letter states the clinic's own rows, rendered and read back", ctx do
      run = issue!(ctx.admin, ctx.credential)

      assert run.render_status == :rendered
      assert run.read_back_status == :passed
      assert run.problems == []
      assert run.document_kind == @kind

      fields = facts(ctx.admin, run)["fields"]

      assert fields["clinic"] == ctx.clinic.name
      assert fields["clinician"] == "Synthetic #{ctx.clinician.last_name}"
      assert fields["credential"] == "Licence"
      assert fields["status"] == "Pending activation"
      assert fields["expires_on"] == "2027-03-31"

      # The credential's number is a secured column the letter never reads.
      refute Jason.encode!(facts(ctx.admin, run)) =~ ctx.credential.number
    end

    test "an expiry date is optional: a credential recorded without one still issues", ctx do
      credential =
        Credentialing.record_credential!(
          %{kind: :certification, number: "SYN-NONE", clinician_id: ctx.clinician.id},
          actor: ctx.admin.actor,
          tenant: ctx.admin.tenant
        )

      run = issue!(ctx.admin, credential)

      assert run.read_back_status == :passed
      fields = facts(ctx.admin, run)["fields"]
      assert fields["credential"] == "Certification"
      refute Map.has_key?(fields, "expires_on")
    end

    test "a member who may read the rows issues the same letter as the admin", ctx do
      reader = member!(ctx.admin, "letter-reader", @readers)

      run = issue!(reader, ctx.credential)

      assert run.read_back_status == :passed
      assert facts(ctx.admin, run)["fields"]["clinic"] == ctx.clinic.name
    end
  end

  describe "the source is read as the actor" do
    test "a person who may not read the credential is refused, and no run row exists", ctx do
      stranger = member!(ctx.admin, "letter-stranger", [])

      assert %PaperError{reason: {:source, {:not_readable, :credential, :not_found}}} =
               unwrap(issue(stranger, ctx.credential))

      assert runs(ctx.admin) == []
    end

    test "a person who may read the credential but not its clinician is refused", ctx do
      partial = member!(ctx.admin, "letter-partial", [{Credential, :read, :global}])

      assert %PaperError{reason: {:source, {:not_readable, :clinician, :forbidden}}} =
               unwrap(issue(partial, ctx.credential))

      assert runs(ctx.admin) == []
    end

    test "a credential in another tenant is not found from this one", ctx do
      other = tenant!()

      assert %PaperError{reason: {:source, {:not_readable, :credential, :not_found}}} =
               unwrap(issue(other, ctx.credential, bind?: true))
    end

    test "a malformed subject is refused before anything runs", ctx do
      for subject <- [%{}, %{"credential_id" => "not-a-uuid"}, %{"credential_id" => 42}] do
        assert %PaperError{reason: {:source, {:invalid_subject, :credential_id}}} =
                 unwrap(issue_subject(ctx.admin, subject))
      end

      assert runs(ctx.admin) == []
    end

    test "a caller cannot put values into the letter: the action takes no source map", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               PaperRun
               |> Ash.ActionInput.for_action(
                 :issue,
                 %{
                   document_kind: @kind,
                   subject: %{"credential_id" => ctx.credential.id},
                   source: %{clinician: "Someone Else"},
                   title: @title
                 },
                 actor: ctx.admin.actor,
                 tenant: ctx.admin.tenant
               )
               |> Ash.run_action()

      # And values smuggled into the subject are not read: only the id is.
      run =
        issue_subject!(ctx.admin, %{
          "credential_id" => ctx.credential.id,
          "clinician" => "Someone Else",
          "status" => "Revoked"
        })

      fields = facts(ctx.admin, run)["fields"]
      assert fields["clinician"] == "Synthetic #{ctx.clinician.last_name}"
      assert fields["status"] == "Pending activation"
    end
  end

  describe "the locale" do
    test "an organization with no default language gets the letter in English", ctx do
      assert CredentialStatusLetter.locale(%{"credential_id" => ctx.credential.id}) == :en

      run = issue!(ctx.admin, ctx.credential)
      assert payload(ctx.admin, run)[:locale] == :en
    end

    test "a French-speaking organization gets the letter in French", ctx do
      set_locale!(ctx.admin, "fr-CA")

      assert CredentialStatusLetter.locale(%{credential_id: ctx.credential.id}) == :fr

      run = issue!(ctx.admin, ctx.credential)
      document = payload(ctx.admin, run)

      assert document[:locale] == :fr
      assert document[:labels]["status"] == "Statut"
      assert facts(ctx.admin, run)["fields"]["status"] == "En attente d'activation"
      assert facts(ctx.admin, run)["fields"]["credential"] == "Permis d'exercice"
    end

    test "a language the kernel does not format falls back to English", ctx do
      set_locale!(ctx.admin, "de-DE")

      assert CredentialStatusLetter.locale(%{"credential_id" => ctx.credential.id}) == :en
    end

    test "a subject that names no credential falls back to English" do
      assert CredentialStatusLetter.locale(%{}) == :en
      assert CredentialStatusLetter.locale(%{"credential_id" => Ecto.UUID.generate()}) == :en
    end
  end

  describe "sealed under the clinician's scope" do
    test "the requester owns the letter; the clinician's scope seals it", ctx do
      reader = member!(ctx.admin, "letter-owner", @readers)
      run = issue!(reader, ctx.credential)

      assert run.owner_id == reader.user.id
      assert run.owner_type == :user
      assert run.erasure_scope_id == scope_of(ctx.admin, ctx.clinician)
      refute run.erasure_scope_id == requester_scope(reader)

      # The requester reads their own run through their owner grants.
      assert {:ok, [mine]} = Documents.my_paper_runs(actor: reader.actor, tenant: reader.tenant)
      assert mine.id == run.id
    end

    test "shredding the clinician's scope erases what the letter said, and its bytes", ctx do
      run = issue!(ctx.admin, ctx.credential)
      version_id = run.document_version_id
      assert %AshEvidence.DocumentVersion{} = version(ctx.admin, version_id)

      shred_scope!(scope_of(ctx.admin, ctx.clinician))

      loaded = sealed(ctx.admin, run)
      assert %Erasure.Shredded{} = loaded.payload
      assert %Erasure.Shredded{} = loaded.facts
      assert %Erasure.Shredded{} = loaded.payload_hash_key

      assert version(ctx.admin, version_id) == nil
      assert parse_runs_for(ctx.admin, version_id) == []
      assert reload(ctx.admin, run).document_version_id == nil
    end

    test "shredding the requester's scope leaves the clinician's letter", ctx do
      reader = member!(ctx.admin, "letter-leaver", @readers)
      run = issue!(reader, ctx.credential)

      shred_scope!(requester_scope(reader))

      loaded = sealed(ctx.admin, run)
      assert loaded.facts["fields"]["clinician"] == "Synthetic #{ctx.clinician.last_name}"
      assert is_map(loaded.payload)
      assert is_binary(loaded.payload_hash_key)
      assert %AshEvidence.DocumentVersion{} = version(ctx.admin, run.document_version_id)
      assert reload(ctx.admin, run).document_version_id == run.document_version_id
    end

    test "two clinicians' scopes share identical bytes: one shred keeps them, the second destroys them",
         ctx do
      # Two clinicians whose letters say the same thing render the same bytes:
      # one content-addressed version, referenced from two clinicians' scopes.
      {twin_a, credential_a} = twin!(ctx)
      {twin_b, credential_b} = twin!(ctx)

      run_a = issue!(ctx.admin, credential_a)
      run_b = issue!(ctx.admin, credential_b)

      assert run_a.erasure_scope_id == scope_of(ctx.admin, twin_a)
      assert run_b.erasure_scope_id == scope_of(ctx.admin, twin_b)
      assert run_a.erasure_scope_id != run_b.erasure_scope_id
      assert run_a.output_digest == run_b.output_digest
      assert run_a.document_version_id
      assert run_a.document_version_id == run_b.document_version_id
      version_id = run_a.document_version_id
      assert [_, _] = parse_runs_for(ctx.admin, version_id)

      shred_scope!(run_a.erasure_scope_id)

      # The living scope still references the bytes: they stay, and only the
      # shredded run lets go of them.
      assert %AshEvidence.DocumentVersion{id: ^version_id} = version(ctx.admin, version_id)
      assert reload(ctx.admin, run_a).document_version_id == nil
      assert reload(ctx.admin, run_b).document_version_id == version_id
      assert [_, _] = parse_runs_for(ctx.admin, version_id)
      assert is_map(sealed(ctx.admin, run_b).facts)

      shred_scope!(run_b.erasure_scope_id)

      # The last reference is gone: the bytes and their derived text go too.
      assert version(ctx.admin, version_id) == nil
      assert parse_runs_for(ctx.admin, version_id) == []

      assert AshEvidence.AddressedAtom
             |> Ash.Query.filter(document_version_id == ^version_id)
             |> Ash.read!(authorize?: false) == []

      assert reload(ctx.admin, run_b).document_version_id == nil
    end

    test "a letter about another clinician survives this clinician's shred", ctx do
      {twin, credential} = twin!(ctx, last_name: "Other#{System.unique_integer([:positive])}")

      run_a = issue!(ctx.admin, ctx.credential)
      run_b = issue!(ctx.admin, credential)

      refute run_a.document_version_id == run_b.document_version_id

      shred_scope!(scope_of(ctx.admin, ctx.clinician))

      assert version(ctx.admin, run_a.document_version_id) == nil
      assert %AshEvidence.DocumentVersion{} = version(ctx.admin, run_b.document_version_id)
      assert reload(ctx.admin, run_b).erasure_scope_id == scope_of(ctx.admin, twin)
    end

    test "a clinician whose scope is shredded cannot be written about: no run row", ctx do
      scope_id = scope_of(ctx.admin, ctx.clinician)
      shred_scope!(scope_id)

      assert %PaperError{reason: {:sealing_scope, {:shredded, ^scope_id}}} =
               unwrap(issue(ctx.admin, ctx.credential))

      assert runs(ctx.admin) == []
    end

    test "a clinician with no scope refuses the letter, never falling back to the requester's",
         ctx do
      AshEnterprise.Repo.query!(
        "UPDATE credentialing_clinicians SET erasure_scope_id = NULL WHERE id = $1",
        [Ecto.UUID.dump!(ctx.clinician.id)]
      )

      assert %PaperError{
               reason: {:sealing_scope, {:unavailable, {:no_erasure_scope, :clinician}}}
             } = unwrap(issue(ctx.admin, ctx.credential))

      assert runs(ctx.admin) == []
    end
  end

  describe "SealingScope.resolve" do
    test "a kind that names no scope is sealed under the requester's, as before" do
      assert SealingScope.resolve(Stubs.NoScope, %{}, []) == {:ok, nil}
      refute SealingScope.names_scope?(Stubs.NoScope)
    end

    test "a scope nobody issued is refused as not found" do
      id = Ecto.UUID.generate()
      assert SealingScope.resolve(Stubs.Fixed, %{"scope" => id}, []) == {:error, {:not_found, id}}
    end

    test "an errored callback is refused, never replaced by the requester's scope" do
      assert SealingScope.resolve(Stubs.Fixed, %{"error" => :unreadable}, []) ==
               {:error, {:unavailable, :unreadable}}
    end

    test "an answer that names no scope is refused" do
      for returned <- [{:ok, nil}, {:ok, "not-a-uuid"}, :ok, nil] do
        assert {:error, {:invalid, _}} =
                 SealingScope.resolve(Stubs.Fixed, %{"return" => returned}, [])
      end
    end

    test "a live scope it names is the one used", ctx do
      scope_id = scope_of(ctx.admin, ctx.clinician)
      assert SealingScope.resolve(Stubs.Fixed, %{"scope" => scope_id}, []) == {:ok, scope_id}
    end
  end

  describe "the stored snapshot" do
    test "the stored snapshot names nobody: no actor, clinician, credential or clinic", ctx do
      other = member!(ctx.admin, "letter-snapshot", @readers)
      run = issue!(other, ctx.credential)

      # The column as stored, not as the resource reads it back.
      %{rows: [[stored]]} =
        AshEnterprise.Repo.query!("SELECT snapshot::text FROM paper_runs WHERE id = $1", [
          Ecto.UUID.dump!(run.id)
        ])

      for personal <- [
            "actor_id",
            other.user.id,
            to_string(other.user.email),
            ctx.admin.user.id,
            ctx.clinician.id,
            ctx.clinician.last_name,
            ctx.credential.id,
            ctx.credential.number,
            ctx.clinic.name
          ] do
        refute stored =~ personal, "the stored snapshot carries #{inspect(personal)}"
      end

      assert Jason.decode!(stored)["snapshot"]["authority"]["tenant"] == ctx.admin.tenant

      # What the letter said is sealed, and goes with the requester's scope.
      shred!(run)

      loaded =
        run.id
        |> Documents.get_paper_run!(tenant: ctx.admin.tenant, authorize?: false)
        |> Ash.load!([:payload, :facts, :payload_hash_key],
          tenant: ctx.admin.tenant,
          authorize?: false
        )

      assert %Erasure.Shredded{} = loaded.payload
      assert %Erasure.Shredded{} = loaded.facts
      assert %Erasure.Shredded{} = loaded.payload_hash_key
    end
  end

  describe "re-render" do
    test "a stored run re-renders from its frozen payload to the same digest", ctx do
      run = issue!(ctx.admin, ctx.credential)
      stored = version(ctx.admin, run.document_version_id)

      loaded =
        run.id
        |> Documents.get_paper_run!(tenant: ctx.admin.tenant, authorize?: false)
        |> Ash.load!([:payload, :facts], tenant: ctx.admin.tenant, authorize?: false)

      assert {:ok, sample} = Rerender.sample(loaded)

      assert {:ok, rendered} =
               AshPaper.Render.render(
                 sample.layout,
                 sample.theme,
                 sample.payload,
                 sample.clauses,
                 Paper.limits()
               )

      assert rendered.digest == run.output_digest
      assert rendered.bytes == stored.bytes

      # Within the engine and fonts the run pinned: every pin the re-render ran
      # under is the one the snapshot recorded.
      engine = AshPaper.Snapshot.pinned(run.snapshot, :engine)
      assert engine != []

      for {key, value} <- rendered.pins do
        assert Enum.any?(engine, &(&1["key"] == to_string(key) and &1["content_hash"] == value)),
               "pin #{key} is not the one the run recorded"
      end
    end

    test "a shredded run cannot be re-rendered: it is unreproducible, not a pass", ctx do
      run = issue!(ctx.admin, ctx.credential)
      shred!(run)

      loaded =
        run.id
        |> Documents.get_paper_run!(tenant: ctx.admin.tenant, authorize?: false)
        |> Ash.load!([:payload, :facts], tenant: ctx.admin.tenant, authorize?: false)

      assert {:unreproducible, :erased} = Rerender.sample(loaded)
    end
  end

  # ── fixtures and helpers ────────────────────────────────────────────────

  defp bind(admin) do
    {:ok, schema, layout, _theme} = Paper.definition(@kind)

    Documents.bind_paper!(
      @kind,
      Paper.binding_purpose(),
      %{
        selection: Paper.selection(schema, layout, Paper.theme("carlito"), admin.tenant),
        backend_profile_hash: AshPaper.Binding.backend_profile_hash(%{"typst" => "pinned"})
      },
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  defp issue(person, credential, opts \\ []) do
    if Keyword.get(opts, :bind?, false), do: bind(person)
    issue_subject(person, %{"credential_id" => credential.id})
  end

  defp issue!(person, credential) do
    assert {:ok, run} = issue(person, credential)
    run
  end

  defp issue_subject(person, subject),
    do:
      Documents.issue_paper_run(@kind, subject, @title,
        actor: person.actor,
        tenant: person.tenant
      )

  defp issue_subject!(person, subject) do
    assert {:ok, run} = issue_subject(person, subject)
    run
  end

  defp unwrap({:error, %PaperError{} = error}), do: error

  defp unwrap({:error, class}) do
    assert [inner] = Enum.filter(class.errors, &match?(%PaperError{}, &1))
    inner
  end

  defp runs(admin) do
    PaperRun
    |> Ash.Query.filter(document_kind == ^@kind)
    |> Ash.read!(tenant: admin.tenant, authorize?: false)
  end

  defp facts(admin, run), do: load(admin, run, :facts)
  defp payload(admin, run), do: load(admin, run, :payload)

  defp load(admin, run, field) do
    run.id
    |> Documents.get_paper_run!(tenant: admin.tenant, authorize?: false)
    |> Ash.load!(field, tenant: admin.tenant, authorize?: false)
    |> Map.fetch!(field)
  end

  defp set_locale!(admin, code) do
    locale =
      LanguageLocale.create!(
        %{
          locale_id: System.unique_integer([:positive]),
          code: code,
          language: code,
          name: "SYNTHETIC #{code}"
        },
        authorize?: false
      )

    Organization
    |> Ash.get!(admin.tenant, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{languagelocale_id: locale.id}, authorize?: false)
    |> Ash.update!()
  end

  defp twin!(ctx, attrs \\ []) do
    opts = [actor: ctx.admin.actor, tenant: ctx.admin.tenant]

    clinician =
      Credentialing.register_clinician!(
        %{
          first_name: "Synthetic",
          last_name: Keyword.get(attrs, :last_name, "Twin"),
          job_title: "Physiotherapist",
          clinic_id: ctx.clinic.id
        },
        opts
      )

    credential =
      Credentialing.record_credential!(
        %{
          kind: :licence,
          number: "SYN-T#{System.unique_integer([:positive])}",
          expires_on: ~D[2027-03-31],
          clinician_id: clinician.id
        },
        opts
      )

    {clinician, credential}
  end

  defp scope_of(admin, clinician) do
    Clinician
    |> Ash.get!(clinician.id, tenant: admin.tenant, authorize?: false)
    |> Map.fetch!(:erasure_scope_id)
  end

  defp requester_scope(person) do
    {:ok, scope} =
      Erasure.scope_by_ref(:data_subject, RequesterScope.scope_ref(person.user.id),
        authorize?: false
      )

    scope.id
  end

  defp sealed(admin, run) do
    run.id
    |> Documents.get_paper_run!(tenant: admin.tenant, authorize?: false)
    |> Ash.load!([:payload, :facts, :payload_hash_key], tenant: admin.tenant, authorize?: false)
  end

  defp shred_scope!(scope_id) do
    scope = Erasure.get_scope!(scope_id, authorize?: false)
    Erasure.shred_scope!(scope, scope.ref, "SYNTHETIC letter test", authorize?: false)
  end

  defp shred!(run) do
    scope = Erasure.get_scope!(run.erasure_scope_id, authorize?: false)
    Erasure.shred_scope!(scope, scope.ref, "SYNTHETIC letter test", authorize?: false)
  end

  defp reload(admin, run),
    do: Documents.get_paper_run!(run.id, tenant: admin.tenant, authorize?: false)

  defp version(_admin, nil), do: nil

  defp version(admin, id) do
    AshEvidence.DocumentVersion
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(tenant: admin.tenant, authorize?: false)
  end

  defp parse_runs_for(admin, version_id) do
    AshEvidence.ParseRun
    |> Ash.Query.filter(document_version_id == ^version_id)
    |> Ash.read!(tenant: admin.tenant, authorize?: false)
  end
end
