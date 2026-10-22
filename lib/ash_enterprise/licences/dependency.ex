defmodule AshEnterprise.Licences.Dependency do
  @moduledoc """
  A third-party package at the version a `mix.lock` resolves: the subject of
  the licence policy (S1-63, `research/s1-63/licence-policy.md` in the
  programme repo).

  The release is the subject, not the package name: a licence can change
  between versions, and the policy judges what we actually ship. The row
  records what the package itself says and ships, never our reading of it:

    * `declared_licences`: the release's own licence declaration, verbatim
      (hex.pm `licenses`). The declaration rung reads it.
    * `licence_text`, `package_files` and `notice_file_present`: what the
      release tarball contains. The model rung reads the text and the file
      names; it is never shown the declaration.

  ## The questions

  The nine `third_party_licence` questions below are Luke Galea's
  confirmation of 2026-10-21 (dogfood record
  `73da9055-7d92-4b2d-9930-acda885f4d48`), rendered by
  `AshEnterprise.SystemOne.QuestionProposal.to_dsl/2` and landed verbatim
  at version 1 with the `:winnow_gpu` decision instrument. Their hashes are
  locked in `priv/judgments/lock.json`, so a wording change is a compile
  error until it arrives with a version bump. Which rung answers a given
  subject is `AshEnterprise.Licences.Rungs`' decision: a declared SPDX id is
  answered without a model.

  Reference data, held per tenant: `:organization_owned`, no lifecycle, and
  no soft delete (a release is never withdrawn from the record, and a soft
  delete would ghost the upsert identity).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Licences,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    extra_extensions: [AshAi, AshJudgments.Registry]

  postgres do
    table "licence_dependencies"
    repo AshEnterprise.Repo
  end

  judgments do
    question :package_licence_is_permissive do
      # judgment:v0:AshEnterprise.Licences.Dependency#judgments/package_licence_is_permissive
      type AshAi.Evaluate.Noul
      instructions("Determine if the declared licence of the package is permissive.")

      criteria(%{
        false:
          "The package is NOT under a permissive licence (e.g., MIT, BSD-2-Clause, BSD-3-Clause, ISC, or Apache-2.0).",
        true:
          "The package IS under a permissive licence (one that only asks us to keep its copyright and licence notice, such as MIT, BSD-2-Clause, BSD-3-Clause, ISC or Apache-2.0)."
      })

      version(1)
      family(:third_party_licence)
      profile(:winnow_gpu)
    end

    question :package_licence_is_strong_copyleft do
      # judgment:v0:AshEnterprise.Licences.Dependency#judgments/package_licence_is_strong_copyleft
      type AshAi.Evaluate.Noul

      instructions(
        "Determine if the declared licence of the package is a strong copyleft licence."
      )

      criteria(%{
        false: "The package is NOT under a strong copyleft licence.",
        true:
          "The package IS under a strong copyleft licence (one that requires the whole combined work to be released under the same licence, such as GPL-2.0 or GPL-3.0)."
      })

      version(1)
      family(:third_party_licence)
      profile(:winnow_gpu)
    end

    question :package_licence_is_weak_copyleft do
      # judgment:v0:AshEnterprise.Licences.Dependency#judgments/package_licence_is_weak_copyleft
      type AshAi.Evaluate.Noul
      instructions("Determine if the declared licence of the package is a weak copyleft licence.")

      criteria(%{
        false: "The package is NOT under a weak copyleft licence.",
        true:
          "The package IS under a weak copyleft licence (file-level or library-level copyleft, such as MPL-2.0 or LGPL-2.1)."
      })

      version(1)
      family(:third_party_licence)
      profile(:winnow_gpu)
    end

    question :package_licence_is_network_copyleft do
      # judgment:v0:AshEnterprise.Licences.Dependency#judgments/package_licence_is_network_copyleft
      type AshAi.Evaluate.Noul

      instructions(
        "Determine if the declared licence of the package is a network copyleft licence."
      )

      criteria(%{
        false: "The package is NOT under a network copyleft licence.",
        true:
          "The package IS under a network copyleft licence (one that extends copyleft to people who use the software over a network, such as AGPL-3.0 or SSPL-1.0)."
      })

      version(1)
      family(:third_party_licence)
      profile(:winnow_gpu)
    end

    question :package_licence_requires_attribution do
      # judgment:v0:AshEnterprise.Licences.Dependency#judgments/package_licence_requires_attribution
      type AshAi.Evaluate.Noul

      instructions(
        "Determine if the package's licence requires attribution (copyright notice or licence text) to travel with copies."
      )

      criteria(%{
        false:
          "The package's licence does NOT require its copyright notice or licence text to travel with copies of the software.",
        true:
          "The package's licence DOES require its copyright notice or licence text to travel with copies of the software."
      })

      version(1)
      family(:third_party_licence)
      profile(:winnow_gpu)
    end

    question :package_requires_notice_file do
      # judgment:v0:AshEnterprise.Licences.Dependency#judgments/package_requires_notice_file
      type AshAi.Evaluate.Noul

      instructions(
        "Determine if the package requires carrying a NOTICE file contents into the distribution."
      )

      criteria(%{
        false:
          "The package is NOT licensed under Apache-2.0 with a NOTICE file, OR it is Apache-2.0 but has no NOTICE file.",
        true: "The package IS licensed under Apache-2.0 and includes a NOTICE file."
      })

      version(1)
      family(:third_party_licence)
      profile(:winnow_gpu)
    end

    question :package_licence_declaration_invalid do
      # judgment:v0:AshEnterprise.Licences.Dependency#judgments/package_licence_declaration_invalid
      type AshAi.Evaluate.Noul

      instructions(
        "Determine if the package's licence declaration is invalid or missing a valid SPDX identifier."
      )

      criteria(%{
        false: "The package declares a valid SPDX licence identifier.",
        true:
          "The package declares no licence, or its declaration is not a valid SPDX licence identifier."
      })

      version(1)
      family(:third_party_licence)
      profile(:winnow_gpu)
    end

    question :package_is_public_domain_dedication do
      # judgment:v0:AshEnterprise.Licences.Dependency#judgments/package_is_public_domain_dedication
      type AshAi.Evaluate.Noul

      instructions(
        "Determine if the package is released under a public-domain dedication or equivalent no-condition licence."
      )

      criteria(%{
        false:
          "The package is NOT released under a public-domain dedication or equivalent licence with no conditions.",
        true:
          "The package IS released under a public-domain dedication or an equivalent licence with no conditions (such as Unlicense, 0BSD or CC0-1.0)."
      })

      version(1)
      family(:third_party_licence)
      profile(:winnow_gpu)
    end

    question :package_licence_has_use_restrictions do
      # judgment:v0:AshEnterprise.Licences.Dependency#judgments/package_licence_has_use_restrictions
      type AshAi.Evaluate.Noul

      instructions(
        "Determine if the package's licence includes restrictions on who may use it or for what purpose."
      )

      criteria(%{
        false: "The package's licence does NOT restrict who may use it or for what purpose.",
        true:
          "The package's licence DOES restrict who may use it or for what purpose (for example, non-commercial use only, or a field-of-use limit)."
      })

      version(1)
      family(:third_party_licence)
      profile(:winnow_gpu)
    end
  end

  actions do
    defaults [:read]

    create :register do
      description "Records a release as a licence subject. Idempotent per release."
      primary? true

      accept [
        :package,
        :version,
        :repository,
        :declared_licences,
        :licence_text,
        :package_files,
        :notice_file_present
      ]

      upsert? true
      upsert_identity :unique_release

      upsert_fields [
        :declared_licences,
        :licence_text,
        :package_files,
        :notice_file_present
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :package, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
      description "The package name, as its repository names it."
    end

    attribute :version, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
      description "The release version a mix.lock resolves."
    end

    attribute :repository, :string do
      allow_nil? false
      public? true
      default "hexpm"
      constraints max_length: 100
      description "The package repository the release comes from."
    end

    attribute :declared_licences, {:array, :string} do
      allow_nil? false
      public? true
      default []
      description "The release's own licence declaration, verbatim. Empty means none declared."
    end

    attribute :licence_text, :string do
      public? true
      constraints trim?: false, allow_empty?: true

      description "The text of the licence files the release tarball ships, or nil when it ships none."
    end

    attribute :package_files, {:array, :string} do
      public? true
      description "The top-level file names in the release tarball, or nil when not read."
    end

    attribute :notice_file_present, :boolean do
      public? true
      description "Whether the release tarball ships a top-level NOTICE file; nil when not read."
    end
  end

  identities do
    identity :unique_release, [:package, :version, :repository]
  end
end
