# ash_mdm usage rules

`ash_mdm` ships resource macros, not concrete resources. The host instantiates
them on its own platform base — host policies, tenancy and audit govern
natively; the package never assumes an actor model.

- Mappings are versioned data with a closed operator vocabulary. Never add an
  eval-based operator; unknown operators are validation errors by design.
- Thresholds (match bands) are never literals in package code — they are host
  band-table decisions. The package carries scores and explanations only.
- Merge is non-destructive: losers keep existing with `merged: true` and a
  `master_id` pointer, per the CDM shape.
