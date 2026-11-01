defmodule AshEnterprise.Assistant.Lookup do
  @moduledoc """
  The assistant's nine read tools: one computed resource per kind of row
  (`AshEnterprise.Assistant.Lookup.CalendarEvent`, `.Conversation`,
  `.Message`, `.Person`, `.Task`, `.Brief`, `.Approval`, `.Duplicate`,
  `.ActivityCount`), each with a single `:read` action that
  `AshEnterprise.Assistant` declares a tool.

  ## Why reads, and why computed

  A run takes an Ash read in its loop: the model sees the rows in the same
  step, and nothing is journalled as a consequence (ADR 0057). Anything
  else a run calls becomes an invocation, which is for what changes the
  world. So each lookup is a `:read` (`read_only?` in its effects), and
  its rows are typed — the attributes of its resource — rather than a map.

  The rows are not stored. Each action is a manual read on the Simple data
  layer (`AshEnterprise.Assistant.Lookups.*`) that runs the canonical
  model's own read actions **as the calling person** (`authorize?: true`,
  owner-only rows and all) and answers with the few fields a model needs,
  with a `ref` it can cite. Sealed content is decrypted only by those
  reads, for its owner (`decrypt_by_default`); there is no other
  decryption path here. The tool offers only the action's own arguments
  (`action_parameters []`): Ash's whole filter and sort vocabulary is a
  schema far too large for a ~27B model, and it could not filter sealed
  attributes anyway (they are ciphertext in the database).

  Self-service (ADR 0052): any active member may ask, for themselves — a
  computed read is admitted outright, like a generic action, because every
  row in it came out of a read filtered as them. Each read also passes the
  zone gate (`AshEnterprise.Assistant.ZoneGate`) before it reads anything,
  and a refusal is the read's error, which the model reads.
  """
end
