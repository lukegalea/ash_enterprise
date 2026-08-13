#!/usr/bin/env python3
"""
Scrape the Dataverse table reference into the same flat intermediate JSON that
resolve.py emits, so the Elixir generator has one input format.

WHY THIS EXISTS
---------------
The Microsoft Common Data Model contains NO security or audit model. Verified
absent from schemaDocuments/: SecurityRole, Privilege, RolePrivileges,
SystemUserRoles, Audit, PluginTraceLog, PrincipalObjectAccess,
FieldSecurityProfile, FieldPermission, TimeZoneDefinition, LanguageLocale.

Those entities exist only in the Dataverse table reference -- as documentation
rather than schema files. Which is awkward, but it is also the *maintained*
half of the picture: the CDM corpus has not changed since March 2023, while
these docs are updated monthly.

It also fills a second gap. The CDM declares `is.constrainedList` in
foundations.cdm.json but no entity ever uses it, so CDM gives us `stateCode` and
`statusCode` as bare integers with no option-set members. These docs DO publish
the choices, which is what makes the AshStateMachine derivation possible. That
is why systemuser/team/businessunit are scraped here too even though the CDM
also describes them -- we take structure from the CDM and option sets from here.

The markdown is machine-generated and highly regular:

    ## Properties                      -> entity-level metadata table
    ## Writable columns/attributes     -> section marker
    ## Read-only columns/attributes    -> section marker
    ### <a name="BKMK_Foo"></a> Foo    -> one column
    |Property|Value|                   -> its metadata
    #### Foo Choices/Options           -> its option set
    |Value|Label|
    ## Many-to-Many relationships      -> intersect tables

Like resolve.py, this runs ONCE, OFFLINE, and its output is committed. Python is
not in the build or CI path.

USAGE
-----
    devenv shell -- python priv/cdm/tools/dataverse_docs.py
    devenv shell -- python priv/cdm/tools/dataverse_docs.py --entity role
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import requests
except ImportError:  # pragma: no cover
    sys.exit(
        "requests is not installed.\n"
        "  devenv shell -- pip install -r priv/cdm/tools/requirements.txt"
    )

REPO_ROOT = Path(__file__).resolve().parents[3]
OUT_DIR = REPO_ROOT / "priv" / "cdm" / "resolved"
CACHE_DIR = REPO_ROOT / "priv" / "cdm" / ".docs_cache"

# Pinned to `main` rather than a SHA: unlike the CDM corpus these docs are
# actively maintained, and we WANT to pick up corrections when we re-run. The
# committed JSON is the stable artifact.
BASE = (
    "https://raw.githubusercontent.com/MicrosoftDocs/powerapps-docs/main"
    "/powerapps-docs/developer/data-platform/reference/entities"
)

# The entities the CDM does not model, plus the three it does model but without
# option sets. `_state_machine_source` marks the latter: for those we keep ONLY
# the option sets and metadata, because their structure comes from the CDM and
# duplicating 136 attributes in two files invites drift.
ENTITIES = [
    # --- security: the whole reason this scraper exists -----------------------
    "role",
    "privilege",
    "roleprivileges",
    "roletemplate",
    "teamtemplate",
    "principalobjectaccess",
    "fieldsecurityprofile",
    "fieldpermission",
    # --- audit ---------------------------------------------------------------
    "audit",
    "plugintracelog",
    # --- reference data ------------------------------------------------------
    "timezonedefinition",
    "languagelocale",
    "transactioncurrency",  # NOTE: the CDM calls this entity "Currency"
    # --- option-set sources for entities the CDM already gives us structure for
    "systemuser",
    "team",
    "businessunit",
    "position",
    "organization",
]

# Intersect (many-to-many) tables are not published in the entity reference --
# these all 404. Their shape is recovered from the IntersectEntityName /
# IntersectAttribute metadata on the parent entity's Many-to-Many section, which
# we capture, and (for TeamMembership) from the CDM, which does model it.
KNOWN_MISSING = {"systemuserroles", "teamroles", "teammembership", "systemuserprofiles"}

BOLD = re.compile(r"^\*\*(.*)\*\*$")
CODE = re.compile(r"^`(.*)`$")
COLUMN_HEADING = re.compile(r'^###\s+<a name="BKMK_[^"]*"></a>\s*(\S+)\s*$')
CHOICES_HEADING = re.compile(r"^####\s+(\S+)\s+Choices/Options\s*$")
TABLE_ROW = re.compile(r"^\|(.+?)\|(.*)\|\s*$")


def snake(name: str) -> str:
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    return s.replace("-", "_").replace(" ", "_").lower()


def clean(value: str) -> str:
    """Strip the markdown emphasis the doc generator wraps values in."""
    v = value.strip()
    for pattern in (BOLD, CODE):
        m = pattern.match(v)
        if m:
            v = m.group(1).strip()
    return v.replace("<br />", " ").strip()


def fetch(entity: str) -> str | None:
    """Fetch one entity's markdown, caching so re-runs are offline and fast."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cached = CACHE_DIR / f"{entity}.md"
    if cached.exists():
        return cached.read_text(encoding="utf-8")

    resp = requests.get(f"{BASE}/{entity}.md", timeout=60)
    if resp.status_code == 404:
        return None
    resp.raise_for_status()
    cached.write_text(resp.text, encoding="utf-8")
    return resp.text


def parse_table(lines: list[str], start: int) -> tuple[dict, int]:
    """
    Parse a `|Property|Value|` table starting at or after `start`.

    Returns the collected pairs and the index just past the table.
    """
    out: dict[str, str] = {}
    i = start
    seen_table = False

    while i < len(lines):
        line = lines[i].strip()
        if not line:
            if seen_table:
                break
            i += 1
            continue
        m = TABLE_ROW.match(line)
        if not m:
            if seen_table:
                break
            i += 1
            continue
        seen_table = True
        key, value = clean(m.group(1)), clean(m.group(2))
        # Skip the header row and the |---|---| separator.
        if key and not set(key) <= {"-", " "} and key.lower() not in ("property",):
            out[key] = value
        i += 1

    return out, i


SUBFIELD = {
    "label": re.compile(r"Label:\s*\*\*(.*?)\*\*"),
    "default_status": re.compile(r"DefaultStatus:\s*(-?\d+)"),
    "invariant_name": re.compile(r"InvariantName:\s*`([^`]*)`"),
    "state": re.compile(r"State:\s*(-?\d+)"),
    "transition_data": re.compile(r"TransitionData:\s*(\S+)"),
}


def parse_choices(lines: list[str], start: int) -> list[dict]:
    """
    Parse a `|Value|Label|` option-set table.

    Plain Picklist choices are simply `|0|**Owner**|`. State and Status choices
    are richer, and this is where the lifecycle model actually lives:

        state_code:  |0|Label: **Active**<br />DefaultStatus: 1<br />InvariantName: `Active`|
        status_code: |1|Label: **Active**<br />State:0<br />TransitionData: None|

    `DefaultStatus` on a state and `State` on a status together give the legal
    (state, status) pairs -- which is exactly the transition table an
    AshStateMachine block needs. The CDM does not carry this at all (it declares
    is.constrainedList but no entity uses it), so this is the ONLY machine-readable
    source we have for it. Flattening these cells to a display string would throw
    the correlation away.
    """
    rows, _ = parse_table(lines, start)
    out = []
    for value, cell in rows.items():
        if value.lower() == "value" or set(value) <= {"-", " "}:
            continue

        member: dict[str, object] = {"value": value}
        matched_any = False
        for key, pattern in SUBFIELD.items():
            m = pattern.search(cell)
            if not m:
                continue
            matched_any = True
            captured = m.group(1)
            if key in ("default_status", "state"):
                member[key] = int(captured)
            elif key == "transition_data" and captured == "None":
                continue
            else:
                member[key] = captured

        # A plain Picklist has no `Label:` prefix -- the whole cell is the label.
        if not matched_any:
            member["label"] = cell

        out.append(member)
    return out


def parse(entity: str, text: str) -> dict:
    lines = text.splitlines()

    entity_props: dict[str, str] = {}
    attributes: list[dict] = []
    many_to_many: list[dict] = []
    many_to_one: list[dict] = []
    description = None

    # Which `## ` section we are inside. This matters more than it looks:
    # EVERY section uses the same `### <a name="BKMK_Foo"></a> Foo` heading
    # shape, including the relationship sections. Treating any such heading as a
    # column silently folds hundreds of relationships into the attribute list
    # (SystemUser came out at 2332 "attributes" instead of ~150).
    section = None
    current: dict | None = None
    i = 0

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # The first plain paragraph after the H1 is the entity description.
        if description is None and stripped and not stripped.startswith(("#", "|", "-", "---")):
            if any(l.startswith("# ") for l in lines[: i + 1]):
                description = stripped

        if stripped.startswith("## "):
            heading = stripped[3:].strip().lower()
            if heading == "properties":
                section = "properties"
                entity_props, i = parse_table(lines, i + 1)
                continue
            if heading.startswith("writable columns"):
                section = "writable"
            elif heading.startswith("read-only columns"):
                section = "readonly"
            elif heading.startswith("many-to-many"):
                section = "m2m"
            elif heading.startswith("many-to-one"):
                section = "m2o"
            elif heading.startswith("one-to-many"):
                section = "o2m"
            else:
                section = None
            current = None
            i += 1
            continue

        m = COLUMN_HEADING.match(stripped)
        if m:
            name = m.group(1)
            props, i = parse_table(lines, i + 1)
            current = None

            if section == "m2m":
                many_to_many.append(
                    {
                        "schema_name": props.get("SchemaName", name),
                        "intersect_entity": props.get("IntersectEntityName"),
                        "intersect_attribute": props.get("IntersectAttribute"),
                        "navigation_property": props.get("NavigationPropertyName"),
                    }
                )
                continue

            if section == "m2o":
                # The FK -> target mapping. Worth keeping: it is how the
                # generator knows `businessunitid` is a belongs_to on
                # BusinessUnit rather than a loose uuid column.
                many_to_one.append(
                    {
                        "schema_name": props.get("SchemaName", name),
                        "referencing_attribute": props.get("ReferencingAttribute"),
                        "referenced_entity": props.get("ReferencedEntity"),
                        "referenced_attribute": props.get("ReferencedAttribute"),
                        "navigation_property": props.get("ReferencingEntityNavigationPropertyName"),
                    }
                )
                continue

            # One-to-many relationships are the inverse of another entity's
            # many-to-one and add nothing we cannot derive, so they are skipped.
            if section not in ("writable", "readonly"):
                continue

            read_only = section == "readonly"
            logical = props.get("LogicalName")
            max_length = props.get("MaxLength")
            targets = props.get("Targets")

            current = {
                "name": name,
                "field": snake(name),
                "source_name": logical,
                # Dataverse type names (Lookup, Picklist, State, Status, Memo,
                # Uniqueidentifier, ...) are NOT the CDM data formats. The Elixir
                # generator maps each vocabulary separately; keeping the raw value
                # means we never have to re-scrape to fix a mapping bug.
                "dataverse_type": props.get("Type"),
                "required_level": (props.get("RequiredLevel") or "").lower() or None,
                "max_length": int(max_length) if (max_length or "").isdigit() else None,
                "display_name": props.get("DisplayName"),
                "description": props.get("Description"),
                "is_read_only": read_only,
                "targets": [t for t in re.split(r"[,\s]+", targets) if t] if targets else None,
                "global_choice_name": props.get("GlobalChoiceName"),
                "default_value": props.get("DefaultFormValue"),
                "enum_values": None,
            }
            attributes.append(current)
            continue

        m = CHOICES_HEADING.match(stripped)
        if m and current is not None:
            current["enum_values"] = parse_choices(lines, i + 1) or None
            i += 1
            continue

        i += 1

    for attr in attributes:
        for key in [k for k, v in attr.items() if v is None]:
            del attr[key]

    logical_name = entity_props.get("LogicalName", entity)
    schema_name = entity_props.get("SchemaName", entity)

    return {
        "entity": schema_name,
        "table": snake(schema_name),
        "source_name": logical_name,
        "display_name": entity_props.get("DisplayName"),
        "description": description,
        "dataverse": {
            "logical_name": logical_name,
            "entity_set": entity_props.get("EntitySetName"),
            "primary_id": entity_props.get("PrimaryIdAttribute"),
            "primary_name": entity_props.get("PrimaryNameAttribute"),
            "table_type": entity_props.get("TableType"),
            # OwnershipType decides which access-control depths even apply:
            # OrganizationOwned tables only support Global/None, while UserOwned
            # support the full Basic/Local/Deep/Global ladder. The generator
            # keys the policy set off this.
            "ownership_type": entity_props.get("OwnershipType"),
        },
        "attributes": attributes,
        "many_to_one": many_to_one,
        "many_to_many": many_to_many,
        "provenance": {
            "source": "MicrosoftDocs/powerapps-docs",
            "document": f"reference/entities/{entity}.md",
            "branch": "main",
            "license": "CC-BY-4.0",
        },
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--entity", action="append", help="Scrape only this entity (repeatable).")
    ap.add_argument(
        "--refresh", action="store_true", help="Ignore the local cache and re-fetch."
    )
    args = ap.parse_args()

    targets = args.entity or ENTITIES
    if args.refresh and CACHE_DIR.exists():
        for f in CACHE_DIR.glob("*.md"):
            f.unlink()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    written = 0
    missing: list[str] = []

    print(f"==> Scraping {len(targets)} Dataverse entities")
    for entity in targets:
        text = fetch(entity)
        if text is None:
            missing.append(entity)
            note = " (expected: intersect tables are not published)" if entity in KNOWN_MISSING else ""
            print(f"  -- {entity:24s} 404{note}")
            continue

        payload = parse(entity, text)
        # Prefix so these never collide with the CDM-resolved files: the CDM's
        # "Currency" and Dataverse's "transactioncurrency" are the same entity
        # under two names, and Team/User/BusinessUnit exist in both corpora.
        out = OUT_DIR / f"dataverse_{snake(payload['entity'])}.json"
        out.write_text(json.dumps(payload, indent=2) + "\n")
        written += 1

        n_enums = sum(1 for a in payload["attributes"] if a.get("enum_values"))
        print(
            f"  ok {payload['entity']:22s} {len(payload['attributes']):4d} cols, "
            f"{n_enums:2d} option sets, {len(payload['many_to_one']):3d} m2o, "
            f"{len(payload['many_to_many'])} m2m  [{payload['dataverse']['ownership_type']}]"
        )

    print(f"\n==> Wrote {written} entities to {OUT_DIR.relative_to(REPO_ROOT)}")
    unexpected = [m for m in missing if m not in KNOWN_MISSING]
    if unexpected:
        print(f"!! Unexpectedly missing (check the doc path): {', '.join(unexpected)}")


if __name__ == "__main__":
    main()
