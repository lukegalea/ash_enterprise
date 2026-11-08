defmodule AshEnterpriseWeb.ArtifactComponents do
  @moduledoc """
  The artifact header and the semantic diff: one presentation for every type in the
  artifact registry (`AshEnterprise.Artifacts`).

    * `artifact_header/1`: what the version is (type, identity, version), where it is in
      its lifecycle, its content hash, what it was copied from, who published it and what
      it references. Opened from a run, it says whether this is the version that run used,
      with the run's test-versus-live cue. A draft is drawn differently (a dashed frame and
      a "Draft" badge, `data-lifecycle="draft"`), so it cannot pass for the version a run
      used.
    * `artifact_diff/1`: the changes `AshEnterprise.Artifacts.diff/4` found, grouped by
      what the type's differ compares. Every other outcome has its own message: no
      semantic diff for the type, a first version, a version that could not be read, a
      comparison that failed, a content change the differ does not cover. Only a
      comparison that ran and found nothing says "No changes".
    * `artifact_validation/1`: `AshEnterprise.Artifacts.validation/2`, where only a check
      that ran and found nothing says the version is valid.

  Imported for every LiveView and html module (through `use AshEnterpriseWeb, :html`).
  """

  use Phoenix.Component
  use Gettext, backend: AshEnterpriseWeb.Gettext

  import AshEnterpriseWeb.CoreComponents, only: [badge: 1]
  import AshEnterpriseWeb.StatusComponents, only: [run_mode: 1, status_message: 1]

  alias AshEnterprise.Artifacts
  alias AshEnterprise.Artifacts.Change

  # --- header --------------------------------------------------------------------

  @doc """
  The header of one version.

  `header` is `AshEnterprise.Artifacts.header/3`; `used_by` is
  `AshEnterprise.Artifacts.used_by/4` for the run the page was opened from; `run_link`
  turns the run's pinned version id into a path when it used another.
  """
  attr :id, :string, default: "artifact-header"
  attr :header, :map, required: true
  attr :used_by, :any, default: nil
  attr :other_version_path, :string, default: nil

  def artifact_header(assigns) do
    assigns = assign(assigns, :class, lifecycle_class(assigns.header.lifecycle))

    ~H"""
    <header
      id={@id}
      data-artifact-type={@header.type}
      data-lifecycle={@class}
      class={[
        "space-y-3 rounded-base border-2 p-4",
        if(@class == :draft,
          do: "border-dashed border-border bg-yellow/10",
          else: "border-border bg-secondary-background"
        )
      ]}
    >
      <p class="text-xs uppercase tracking-wide text-foreground/70">{@header.label}</p>
      <div class="flex flex-wrap items-baseline gap-2">
        <h2 id={"#{@id}-identity"} class="font-heading text-xl break-all">
          {@header.identity || dgettext("artifacts", "Unnamed")}
        </h2>
        <.badge :if={@header.version} id={"#{@id}-version"}>
          {dgettext("artifacts", "version %{version}", version: @header.version)}
        </.badge>
        <.lifecycle_badge id={"#{@id}-lifecycle"} lifecycle={@header.lifecycle} />
      </div>

      <p :if={@class == :draft} id={"#{@id}-draft-note"} class="text-sm">
        {dgettext(
          "artifacts",
          "A draft: no run uses it, and none will until it is published."
        )}
      </p>

      <.used_by
        id={"#{@id}-run"}
        used_by={@used_by}
        class={@class}
        other_version_path={@other_version_path}
      />

      <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
        <dt>{dgettext("artifacts", "Content hash")}</dt>
        <dd id={"#{@id}-hash"} class="font-mono text-xs break-all">
          {short(@header.content_hash) || dgettext("artifacts", "none recorded")}
        </dd>
        <dt :if={@header.parent}>{dgettext("artifacts", "Copied from")}</dt>
        <dd :if={@header.parent} id={"#{@id}-parent"} class="font-mono text-xs break-all">
          {@header.parent}
        </dd>
        <dt>{dgettext("artifacts", "Published by")}</dt>
        <dd id={"#{@id}-published-by"} data-published-by={published_state(@header.published_by)}>
          {published_by(@header.published_by)}
        </dd>
        <dt :if={@header.references != []}>{dgettext("artifacts", "References")}</dt>
        <dd :if={@header.references != []}>
          <ul id={"#{@id}-references"} class="flex flex-wrap gap-1">
            <li :for={{kind, name} <- @header.references}>
              <.badge class="font-mono">{kind}: {name}</.badge>
            </li>
          </ul>
        </dd>
      </dl>
    </header>
    """
  end

  attr :id, :string, required: true
  attr :lifecycle, :any, required: true

  defp lifecycle_badge(%{lifecycle: nil} = assigns), do: ~H""

  defp lifecycle_badge(assigns) do
    {state, class} = assigns.lifecycle
    assigns = assign(assigns, state: state, class: class)

    ~H"""
    <.badge id={@id} tone={tone(@class)} data-lifecycle={@class} data-state={@state}>
      {lifecycle_label(@class)}
      <span class="font-mono">{@state}</span>
    </.badge>
    """
  end

  attr :id, :string, required: true
  attr :used_by, :any, required: true
  attr :class, :atom, required: true
  attr :other_version_path, :string, default: nil

  defp used_by(%{used_by: nil} = assigns), do: ~H""

  defp used_by(%{used_by: :unreadable} = assigns) do
    ~H"""
    <p id={@id} data-used-by="unreadable" class="text-sm">
      {dgettext(
        "artifacts",
        "The run this page was opened from could not be read, so it is not known whether it used this version."
      )}
    </p>
    """
  end

  defp used_by(%{used_by: {:this, run}} = assigns) do
    assigns = assign(assigns, :run, run)

    ~H"""
    <p id={@id} data-used-by="this" class="flex flex-wrap items-center gap-2 text-sm">
      <span>
        {dgettext("artifacts", "The version run %{run} used.", run: short(@run.id))}
      </span>
      <.run_mode mode={Map.get(@run, :mode)} id={"#{@id}-mode"} />
    </p>
    """
  end

  defp used_by(%{used_by: {:other, run}} = assigns) do
    assigns = assign(assigns, :run, run)

    ~H"""
    <p id={@id} data-used-by="other" class="flex flex-wrap items-center gap-2 text-sm">
      <span>
        {dgettext("artifacts", "Not the version run %{run} used.", run: short(@run.id))}
      </span>
      <.link
        :if={@other_version_path}
        id={"#{@id}-used"}
        navigate={@other_version_path}
        class="underline"
      >
        {dgettext("artifacts", "Open the version it used")}
      </.link>
      <.run_mode mode={Map.get(@run, :mode)} id={"#{@id}-mode"} />
    </p>
    """
  end

  # --- diff ----------------------------------------------------------------------

  @doc """
  The semantic diff of one version against another.

  `state` is `AshEnterprise.Artifacts.diff/4`; `aspects` the differ's `aspects/0`;
  `from_label` names the version compared with ("version 2").
  """
  attr :id, :string, default: "artifact-diff"
  attr :state, :any, required: true
  attr :aspects, :list, required: true
  attr :from_label, :string, default: nil

  def artifact_diff(assigns) do
    assigns = assign(assigns, :name, state_name(assigns.state))

    ~H"""
    <section id={@id} data-diff-state={@name} class="space-y-3">
      <h3 class="font-heading text-lg">
        {if @from_label,
          do: dgettext("artifacts", "Changes since %{version}", version: @from_label),
          else: dgettext("artifacts", "Changes")}
      </h3>
      <p :if={@aspects != []} id={"#{@id}-compares"} class="text-sm text-foreground/70">
        {dgettext("artifacts", "Compares: %{aspects}.",
          aspects:
            Enum.map_join(@aspects, ", ", fn {_aspect, label} -> Artifacts.translate(label) end)
        )}
      </p>
      <.diff_body id={@id} state={@state} aspects={@aspects} />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :state, :any, required: true
  attr :aspects, :list, required: true

  defp diff_body(%{state: {:changes, [_ | _] = changes}} = assigns) do
    assigns = assign(assigns, :groups, group(changes, assigns.aspects))

    ~H"""
    <div id={"#{@id}-changes"} class="space-y-3">
      <section :for={{aspect, label, changes} <- @groups} id={"#{@id}-#{aspect}"} data-aspect={aspect}>
        <h4 class="font-heading">{label}</h4>
        <ul class="list-disc pl-5 text-sm">
          <li :for={change <- changes} data-change-kind={change.kind}>
            <.change change={change} />
          </li>
        </ul>
      </section>
    </div>
    """
  end

  defp diff_body(assigns) do
    {kind, role} = message_kind(assigns.state)
    assigns = assign(assigns, kind: kind, role: role)

    ~H"""
    <.status_message id={"#{@id}-message"} kind={@kind} role={@role}>
      {message(@state)}
    </.status_message>
    """
  end

  attr :change, Change, required: true

  defp change(%{change: %Change{kind: :added}} = assigns) do
    ~H"""
    <span class="font-semibold">{dgettext("artifacts", "Added")}</span>
    <span class="font-mono">{@change.subject}</span>
    <span :if={not is_nil(@change.to)} class="text-foreground/70">{value(@change.to)}</span>
    """
  end

  defp change(%{change: %Change{kind: :removed}} = assigns) do
    ~H"""
    <span class="font-semibold">{dgettext("artifacts", "Removed")}</span>
    <span class="font-mono">{@change.subject}</span>
    <span :if={not is_nil(@change.from)} class="text-foreground/70">{value(@change.from)}</span>
    """
  end

  defp change(assigns) do
    ~H"""
    <span class="font-semibold">{dgettext("artifacts", "Changed")}</span>
    <span :if={@change.subject} class="font-mono">{@change.subject}</span>
    <span :if={@change.option} class="font-mono">{@change.option}</span>:
    <span class="font-mono">{value(@change.from)}</span>
    <span aria-hidden="true">→</span>
    <span class="sr-only">{dgettext("artifacts", "to")}</span>
    <span class="font-mono">{value(@change.to)}</span>
    """
  end

  # --- validation ----------------------------------------------------------------

  @doc "A version checked again: `AshEnterprise.Artifacts.validation/2`."
  attr :id, :string, default: "artifact-validation"
  attr :validation, :any, required: true

  def artifact_validation(assigns) do
    assigns = assign(assigns, :name, validation_name(assigns.validation))

    ~H"""
    <section id={@id} data-validation={@name} class="space-y-2">
      <h3 class="font-heading text-lg">{dgettext("artifacts", "Validation")}</h3>
      <.validation_body id={@id} validation={@validation} />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :validation, :any, required: true

  defp validation_body(%{validation: {:ok, []}} = assigns) do
    ~H"""
    <.status_message id={"#{@id}-message"} kind={:success}>
      {dgettext("artifacts", "Checked: no problems found.")}
    </.status_message>
    """
  end

  defp validation_body(%{validation: {:ok, problems}} = assigns) do
    assigns = assign(assigns, :problems, problems)

    ~H"""
    <.status_message id={"#{@id}-message"} kind={:warning}>
      {dngettext(
        "artifacts",
        "Checked: %{count} problem.",
        "Checked: %{count} problems.",
        length(@problems)
      )}
    </.status_message>
    <ul id={"#{@id}-problems"} class="list-disc pl-5 text-sm">
      <li :for={problem <- @problems}>{problem}</li>
    </ul>
    """
  end

  defp validation_body(%{validation: :undeclared} = assigns) do
    ~H"""
    <.status_message id={"#{@id}-message"} kind={:info}>
      {dgettext("artifacts", "Not checked: this type declares no check.")}
    </.status_message>
    """
  end

  defp validation_body(%{validation: {:failed, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <.status_message id={"#{@id}-message"} kind={:warning}>
      {not_checked(@reason)}
    </.status_message>
    """
  end

  # --- words ---------------------------------------------------------------------

  @doc "The class of a lifecycle: `draft`, `current`, `past`, `unknown`, or `none`."
  @spec lifecycle_class({atom(), atom()} | nil) :: atom()
  def lifecycle_class(nil), do: :none
  def lifecycle_class({_state, class}), do: class

  @doc "The name of a diff state, for `data-diff-state`."
  @spec state_name(Artifacts.state()) :: String.t()
  def state_name({:changes, [_ | _]}), do: "changes"
  def state_name({:unchanged, :same_content}), do: "unchanged"
  def state_name({:unchanged, :compared}), do: "unchanged"
  def state_name(:uncovered), do: "uncovered"
  def state_name(:no_differ), do: "no-differ"
  def state_name(:first), do: "first"
  def state_name(:unchained), do: "unchained"
  def state_name({:unreadable, :from}), do: "unreadable"
  def state_name(_failed), do: "failed"

  defp validation_name({:ok, []}), do: "valid"
  defp validation_name({:ok, _problems}), do: "problems"
  defp validation_name(:undeclared), do: "undeclared"
  defp validation_name(_failed), do: "not-checked"

  defp message({:unchanged, :same_content}),
    do: dgettext("artifacts", "No changes: the content is the same.")

  defp message({:unchanged, :compared}),
    do: dgettext("artifacts", "No changes in anything this comparison covers.")

  defp message(:uncovered) do
    dgettext(
      "artifacts",
      "The content differs, but not in anything this comparison covers (an order or formatting change, say). Treat it as changed."
    )
  end

  defp message(:no_differ),
    do: dgettext("artifacts", "No semantic diff for this type. Changes cannot be shown here.")

  defp message(:first),
    do: dgettext("artifacts", "The first version: there is nothing earlier to compare with.")

  defp message(:unchained) do
    dgettext(
      "artifacts",
      "This type keeps no earlier versions. Choose another one to compare with."
    )
  end

  defp message({:unreadable, :from}) do
    dgettext(
      "artifacts",
      "The version to compare with could not be read, so no changes are shown. That is not the same as no changes."
    )
  end

  defp message(_failed) do
    dgettext(
      "artifacts",
      "The comparison failed, so no changes are shown. That is not the same as no changes."
    )
  end

  defp message_kind({:unchanged, _how}), do: {:success, "status"}
  defp message_kind(state) when state in [:no_differ, :first, :unchained], do: {:info, "status"}
  defp message_kind(:uncovered), do: {:warning, "status"}
  defp message_kind(_unreadable_or_failed), do: {:error, "alert"}

  defp not_checked(:not_compiled),
    do: dgettext("artifacts", "Not checked: this version has not been compiled.")

  defp not_checked(:not_validated),
    do: dgettext("artifacts", "Not checked: this version has not been validated yet.")

  defp not_checked(:gate_not_run),
    do: dgettext("artifacts", "Not checked: the release gate has not run on it.")

  defp not_checked(_reason),
    do: dgettext("artifacts", "Not checked: the check could not run.")

  defp lifecycle_label(:draft), do: dgettext("artifacts", "Draft")
  defp lifecycle_label(:current), do: dgettext("artifacts", "In use")
  defp lifecycle_label(:past), do: dgettext("artifacts", "No longer used")
  defp lifecycle_label(_unknown), do: dgettext("artifacts", "Lifecycle unknown")

  defp tone(:draft), do: "yellow"
  defp tone(:current), do: "green"
  defp tone(:past), do: "neutral"
  defp tone(_unknown), do: "red"

  defp published_state({:ok, _name}), do: "recorded"
  defp published_state(:not_recorded), do: "not-recorded"
  defp published_state(_unreadable), do: "unreadable"

  defp published_by({:ok, name}), do: name
  defp published_by(:not_recorded), do: dgettext("artifacts", "No publish recorded")

  defp published_by(_unreadable),
    do: dgettext("artifacts", "Not shown: you may not read the audit trail")

  defp group(changes, aspects) do
    known = Enum.map(aspects, &elem(&1, 0))
    by_aspect = Enum.group_by(changes, & &1.aspect)

    named =
      for {aspect, label} <- aspects,
          list = by_aspect[aspect],
          list != nil,
          do: {aspect, Artifacts.translate(label), list}

    # A change under an aspect the differ does not list still shows, under its own name.
    other =
      for {aspect, list} <- by_aspect, aspect not in known, do: {aspect, to_string(aspect), list}

    named ++ other
  end

  defp value(:unread), do: dgettext("artifacts", "could not be read")
  defp value(nil), do: dgettext("artifacts", "none")
  defp value(true), do: dgettext("artifacts", "yes")
  defp value(false), do: dgettext("artifacts", "no")

  defp value(text) when is_binary(text) do
    if Regex.match?(~r/\A[0-9a-f]{40,}\z/, text), do: short(text), else: truncate(text)
  end

  defp value(other) when is_atom(other) or is_number(other), do: to_string(other)

  defp value(other) do
    case Jason.encode(other) do
      {:ok, json} -> truncate(json)
      {:error, _not_json} -> truncate(inspect(other))
    end
  end

  defp truncate(text) when byte_size(text) > 160, do: String.slice(text, 0, 157) <> "…"
  defp truncate(text), do: text

  defp short(nil), do: nil
  defp short(text) when is_binary(text), do: String.slice(text, 0, 12)
  defp short(other), do: to_string(other)
end
