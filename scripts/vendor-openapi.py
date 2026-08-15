#!/usr/bin/env python3
"""Normalise the vendored HQBase Mail API v1 spec for swift-openapi-generator.

Why this exists: the upstream spec expresses nullable properties as OAS 3.1
`anyOf: [ {..}, {type: "null"} ]`. swift-openapi-generator 1.7 does not support
the null type: it logs "Schema null is not supported ... skipping" and DROPS THE
PROPERTY ENTIRELY from the generated types (it does NOT emit an optional, as was
previously assumed). That silently loses readAt/starredAt/mailboxId/nextCursor/…

Fix: rewrite each `anyOf: [S, {type: null}]` to plain `S`, and remove the
property name from its object's `required` list so the generator emits a Swift
Optional. Semantics are preserved for our client (absent == null).

Usage (idempotent):
    python3 scripts/vendor-openapi.py [path-to-openapi.json]

Run this after refreshing HeraldKit/Sources/HeraldAPI/openapi.json from upstream
`api/hqbase-mail-api-v1.openapi.json`.
"""

import json
import sys
from pathlib import Path

DEFAULT = Path(__file__).resolve().parent.parent / "HeraldKit/Sources/HeraldAPI/openapi.json"


def is_null_schema(schema):
    return isinstance(schema, dict) and schema.get("type") == "null"


def unwrap_nullable(schema):
    """Return (unwrapped_schema, was_nullable)."""
    if not isinstance(schema, dict):
        return schema, False
    branches = schema.get("anyOf") or schema.get("oneOf")
    if not isinstance(branches, list) or len(branches) != 2:
        return schema, False
    non_null = [b for b in branches if not is_null_schema(b)]
    if len(non_null) != 1 or len(branches) - len(non_null) != 1:
        return schema, False
    merged = dict(non_null[0])
    for key, value in schema.items():
        if key not in ("anyOf", "oneOf") and key not in merged:
            merged[key] = value
    return merged, True


def walk(node, changed):
    if isinstance(node, list):
        return [walk(item, changed) for item in node]
    if not isinstance(node, dict):
        return node

    node = {key: walk(value, changed) for key, value in node.items()}

    props = node.get("properties")
    if isinstance(props, dict):
        nullable_names = []
        for name, sub in list(props.items()):
            unwrapped, was_nullable = unwrap_nullable(sub)
            if was_nullable:
                props[name] = unwrapped
                nullable_names.append(name)
                changed.append(name)
        if nullable_names and isinstance(node.get("required"), list):
            node["required"] = [r for r in node["required"] if r not in nullable_names]
            if not node["required"]:
                del node["required"]
    return node


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    spec = json.loads(path.read_text())
    changed = []
    spec = walk(spec, changed)
    path.write_text(json.dumps(spec, indent=2) + "\n")
    print(f"{path}: relaxed {len(changed)} nullable properties: {sorted(set(changed))}")


if __name__ == "__main__":
    main()
