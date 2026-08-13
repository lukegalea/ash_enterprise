#!/usr/bin/env python3
"""
Resolve vendored Microsoft CDM entities into a flat intermediate JSON format.

WHY THIS IS PYTHON
------------------
CDM entity documents are not flat schemas. Reading one correctly means resolving
trait inheritance through purposes and dataTypes, flattening nested attribute
groups (every CDM entity wraps its own columns in an inline group named
`attributesAddedAtThisScope`), and executing `resolutionGuidance` to project
foreign-key attributes -- including `renameFormat`, `referenceOnlyAfterDepth`,
and polymorphic entity references like the User|Team owner.

Microsoft's object model already does all of that in
`CdmEntityDefinition.create_resolved_entity_async`. Reimplementing it in Elixir
would be hundreds of hours for a strictly worse result.

So: this script runs ONCE, OFFLINE, and commits its output. Python is never in
the build path, never in CI, and never a runtime dependency. The Elixir
generator (`mix cdm.gen.resource`) consumes only the committed JSON in
priv/cdm/resolved/.

USAGE
-----
    devenv shell -- python priv/cdm/tools/resolve.py
    devenv shell -- python priv/cdm/tools/resolve.py --entity User --entity Team

Requires `commondatamodel-objectmodel` (see requirements.txt).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import sys
from pathlib import Path
from typing import Any

try:
    from cdm.objectmodel import CdmCorpusDefinition
    from cdm.storage import LocalAdapter
    from cdm.enums import CdmStatusLevel
except ImportError:  # pragma: no cover
    sys.exit(
        "commondatamodel-objectmodel is not installed.\n"
        "  devenv shell -- pip install -r priv/cdm/tools/requirements.txt"
    )

REPO_ROOT = Path(__file__).resolve().parents[3]
SCHEMA_ROOT = REPO_ROOT / "priv" / "cdm" / "schemaDocuments"
OUT_DIR = REPO_ROOT / "priv" / "cdm" / "resolved"
MANIFEST = "local:/core/applicationCommon/applicationCommon.manifest.cdm.json"

# Pinned upstream commit, stamped into every output file so a generated Ash
# resource can always be traced back to the exact schema revision it came from.
CDM_SHA = "dd21d715e05ebf740a11356c80b5c3b4c38a89c2"

VERSIONED = re.compile(r"\.[0-9]+(\.[0-9]+)*\.(manifest\.)?cdm\.json$")


def snake(name: str) -> str:
    """CamelCase / camelCase -> snake_case, for Elixir-side identifiers."""
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    return s.replace("-", "_").replace(" ", "_").lower()


def trait_named(attr: Any, name: str) -> Any | None:
    """Find an applied trait by name on a resolved attribute."""
    for t in getattr(attr, "applied_traits", None) or []:
        if getattr(t, "named_reference", None) == name:
            return t
    return None


def trait_arg(trait: Any, arg_name: str) -> Any:
    """
    Read a named argument's value off a trait reference.

    Single-parameter traits (`is.CDS.sourceNamed`, `is.CDS.lookup`,
    `is.requiredAtLevel`, ...) are almost always written positionally in the
    corpus, so the resolved argument carries `name = None` and matching purely
    on the name silently returns nothing. Fall back to the sole argument when
    there is exactly one -- an unnamed argument on a one-parameter trait is
    unambiguous by definition.
    """
    if trait is None:
        return None

    args = list(getattr(trait, "arguments", None) or [])
    if not args:
        return None

    for arg in args:
        if getattr(arg, "name", None) == arg_name:
            return getattr(arg, "value", None)

    if len(args) == 1 and getattr(args[0], "name", None) in (None, ""):
        return getattr(args[0], "value", None)

    return None


def localized(trait: Any) -> str | None:
    """
    Pull the English string out of an `is.localized.*` trait.

    The value is a ConstantEntity whose constant_values is a table of
    [languageTag, displayText] rows. In practice the corpus only carries "en".
    """
    if trait is None:
        return None
    for arg in getattr(trait, "arguments", None) or []:
        val = getattr(arg, "value", None)
        ent = getattr(val, "explicit_reference", None) or val
        rows = getattr(ent, "constant_values", None)
        if not rows:
            continue
        for row in rows:
            if len(row) >= 2 and row[0] == "en":
                return row[1]
    return None


def required_level(attr: Any) -> str | None:
    """`is.requiredAtLevel` -> none | required | systemrequired | applicationrequired."""
    return trait_arg(trait_named(attr, "is.requiredAtLevel"), "level")


def enum_values(attr: Any) -> list[dict] | None:
    """
    Extract option-set members from `is.constrainedList*` traits.

    The constant entity is a table whose column layout is determined by which
    entity shape the trait uses, and the shapes extend each other:

        localizedTable              [languageTag, displayText]
        listLookupValues            + [attributeValue, displayOrder]
        listLookupCorrelatedValues  + [correlatedValue]
        listLookupWellKnownValues   + [description, uniqueIdentifier]

    The `correlatedValue` column is the interesting one: on a `statusCode`
    attribute the correlated value is the `stateCode` the status belongs to, so
    the legal (state, status) pairs come out of the schema rather than being
    transcribed by hand into an AshStateMachine block.

    ⚠️ VERIFIED 2026-08-13: the vendored corpus does NOT actually use these
    traits. `is.constrainedList*` appears only in foundations.cdm.json, where it
    is DEFINED; no entity under core/applicationCommon references it. Every
    entity carries `stateCode`/`statusCode` as bare integers alongside
    `stateCode_display`/`statusCode_display` companions, with no option-set
    members and no correlation.

    So this function currently returns None for the whole corpus, and it is kept
    for two reasons: other CDM verticals may populate these traits, and the
    Dataverse table reference (which DOES document the option sets, including
    the statecode/statuscode correlation) is normalized by dataverse_docs.py
    into this same field. The state-machine derivation is driven from there --
    see docs/adr/0001.
    """
    for tname in (
        "is.constrainedList.wellKnown",
        "is.constrainedList.correlated",
        "is.constrainedList.string",
        "is.constrainedList",
    ):
        trait = trait_named(attr, tname)
        if trait is None:
            continue

        correlated = tname == "is.constrainedList.correlated"
        well_known = tname == "is.constrainedList.wellKnown"

        for arg in getattr(trait, "arguments", None) or []:
            val = getattr(arg, "value", None)
            ent = getattr(val, "explicit_reference", None) or val
            rows = getattr(ent, "constant_values", None)
            if not rows:
                continue

            out = []
            for row in rows:
                if len(row) < 3 or row[0] != "en":
                    continue
                member: dict[str, Any] = {"label": row[1], "value": row[2]}
                if len(row) > 3 and row[3] not in (None, ""):
                    member["display_order"] = row[3]
                if correlated and len(row) > 4 and row[4] not in (None, ""):
                    # For statusCode this is the owning stateCode.
                    member["correlated_value"] = row[4]
                if well_known and len(row) > 5 and row[5] not in (None, ""):
                    member["identifier"] = row[5]
                out.append(member)

            if out:
                return out
    return None


def describe_attribute(attr: Any) -> dict:
    """Flatten one resolved CDM attribute into our intermediate shape."""
    name = getattr(attr, "name", None)
    data_format = getattr(attr, "data_format", None)
    fmt = getattr(data_format, "name", None) or (
        str(data_format) if data_format is not None else None
    )

    source_name = trait_arg(trait_named(attr, "is.CDS.sourceNamed"), "name")
    lookup_style = trait_arg(trait_named(attr, "is.CDS.lookup"), "style")

    out = {
        "name": name,
        "field": snake(name) if name else None,
        # `sourceName` is the physical Dataverse column (lowercase); `name` is
        # the CDM logical name. We keep both -- the former for interop, the
        # latter because it is what the rest of the corpus references.
        "source_name": source_name,
        "data_format": fmt,
        "required_level": required_level(attr),
        "max_length": getattr(attr, "maximum_length", None),
        "display_name": localized(trait_named(attr, "is.localized.displayedAs")),
        "description": localized(trait_named(attr, "is.localized.describedAs")),
        "is_primary_key": trait_named(attr, "is.identifiedBy") is not None,
        "is_read_only": trait_named(attr, "is.readOnly") is not None,
        "is_nullable": getattr(attr, "is_nullable", None),
        # Dataverse semantic markers we key on when generating policies and
        # polymorphic relationships.
        "cds": {
            "lookup_style": lookup_style,
            "is_owner": trait_named(attr, "is.CDS.owner") is not None,
            "is_customer": trait_named(attr, "is.CDS.customer") is not None,
            "is_party_list": trait_named(attr, "is.CDS.partyList") is not None,
            "is_standard": trait_named(attr, "is.CDS.standard") is not None,
        },
        "enum_values": enum_values(attr),
    }
    return {k: v for k, v in out.items() if v is not None and v != {}}


async def resolve_all(only: set[str] | None) -> dict[str, dict]:
    corpus = CdmCorpusDefinition()

    # Mount the vendored tree under BOTH namespaces. Documents reference
    # foundations via `cdm:/foundations.cdm.json`, and since the CDM Schema
    # Store was shut down in March 2024 there is no remote to resolve that
    # against -- it has to point at our local copy.
    adapter = LocalAdapter(root=str(SCHEMA_ROOT))
    corpus.storage.mount("local", adapter)
    corpus.storage.mount("cdm", adapter)
    corpus.storage.default_namespace = "local"

    errors: list[str] = []
    corpus.set_event_callback(
        lambda level, msg: errors.append(msg) if level >= CdmStatusLevel.ERROR else None,
        CdmStatusLevel.ERROR,
    )

    manifest = await corpus.fetch_object_async(MANIFEST)
    if manifest is None:
        raise SystemExit(f"Could not load manifest {MANIFEST}\n" + "\n".join(errors))

    results: dict[str, dict] = {}
    for decl in manifest.entities:
        entity_name = decl.entity_name
        if only and entity_name not in only:
            continue

        path = getattr(decl, "entity_path", None) or getattr(decl, "entity_schema", None)
        entity = await corpus.fetch_object_async(path, manifest)
        if entity is None:
            print(f"  !! could not fetch {entity_name} ({path})", file=sys.stderr)
            continue

        resolved = await entity.create_resolved_entity_async(f"R_{entity_name}")
        if resolved is None:
            print(f"  !! could not resolve {entity_name}", file=sys.stderr)
            continue

        attrs = [describe_attribute(a) for a in resolved.attributes]
        results[entity_name] = {
            "entity": entity_name,
            "table": snake(entity_name),
            "source_name": getattr(entity, "source_name", None) or entity_name,
            "display_name": localized(
                trait_named(entity, "is.localized.displayedAs")
            ),
            "description": localized(trait_named(entity, "is.localized.describedAs")),
            "attributes": attrs,
            "provenance": {
                "source": "microsoft/CDM",
                "commit": CDM_SHA,
                "document": path,
                "license": "CC-BY-4.0",
            },
        }
        print(f"  ok {entity_name:24s} {len(attrs):4d} attributes")

    if errors:
        print(f"\n{len(errors)} resolver error(s); first few:", file=sys.stderr)
        for e in errors[:5]:
            print(f"  - {e}", file=sys.stderr)

    return results


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--entity",
        action="append",
        help="Resolve only this entity (repeatable). Default: everything in the manifest.",
    )
    args = ap.parse_args()
    only = set(args.entity) if args.entity else None

    print(f"==> Resolving CDM entities from {SCHEMA_ROOT}")
    results = asyncio.run(resolve_all(only))

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, payload in results.items():
        (OUT_DIR / f"{snake(name)}.json").write_text(
            json.dumps(payload, indent=2, sort_keys=False) + "\n"
        )

    print(f"\n==> Wrote {len(results)} entities to {OUT_DIR.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
