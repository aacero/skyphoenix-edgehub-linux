"""Shared helpers for agent-framework scripts. Stdlib only — the template must not require pip installs."""
from __future__ import annotations

import datetime
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
FRAMEWORK_DIR = REPO_ROOT / "agent-framework"


def load_json(path: Path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


class SchemaError(Exception):
    pass


def validate_schema(instance, schema, path="$"):
    """Minimal JSON-Schema validator covering the subset used by agent-framework schemas:
    type, required, properties, additionalProperties(bool), enum, items, anyOf,
    minLength, minimum/maximum/exclusiveMinimum, minItems, pattern, and
    format: date-time (ENFORCED — an unparseable timestamp is a violation; other
    formats are not used by the framework schemas and raise as unsupported).
    Raises SchemaError with a JSON-path message on the first violation."""
    t = schema.get("type")
    if t is not None:
        types = t if isinstance(t, list) else [t]
        if not any(_type_ok(instance, x) for x in types):
            raise SchemaError(f"{path}: expected type {t}, got {type(instance).__name__}")
    if "enum" in schema and instance not in schema["enum"]:
        raise SchemaError(f"{path}: {instance!r} not in enum {schema['enum']}")
    if "anyOf" in schema:
        errs = []
        for i, sub in enumerate(schema["anyOf"]):
            try:
                validate_schema(instance, sub, f"{path}(anyOf[{i}])")
                break
            except SchemaError as e:
                errs.append(str(e))
        else:
            raise SchemaError(f"{path}: no anyOf branch matched: {'; '.join(errs)}")
    if isinstance(instance, dict):
        for req in schema.get("required", []):
            if req not in instance:
                raise SchemaError(f"{path}: missing required key '{req}'")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            extra = set(instance) - set(props)
            if extra:
                raise SchemaError(f"{path}: unexpected keys {sorted(extra)}")
        for k, v in instance.items():
            if k in props:
                validate_schema(v, props[k], f"{path}.{k}")
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            raise SchemaError(f"{path}: fewer than {schema['minItems']} items")
        if "items" in schema:
            for i, v in enumerate(instance):
                validate_schema(v, schema["items"], f"{path}[{i}]")
    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            raise SchemaError(f"{path}: shorter than minLength {schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            raise SchemaError(f"{path}: does not match pattern {schema['pattern']}")
        fmt = schema.get("format")
        if fmt == "date-time":
            try:
                datetime.datetime.fromisoformat(instance)
            except ValueError:
                raise SchemaError(f"{path}: {instance!r} is not a valid ISO-8601 date-time")
        elif fmt is not None:
            # Declared-but-unenforced constraints are not accepted (verification
            # finding 6): a schema author adding a new format must implement it.
            raise SchemaError(f"{path}: schema declares unsupported format {fmt!r}")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            raise SchemaError(f"{path}: {instance} < minimum {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            raise SchemaError(f"{path}: {instance} > maximum {schema['maximum']}")
        if "exclusiveMinimum" in schema and instance <= schema["exclusiveMinimum"]:
            raise SchemaError(f"{path}: {instance} <= exclusiveMinimum {schema['exclusiveMinimum']}")


def _type_ok(v, t):
    return {
        "object": lambda: isinstance(v, dict),
        "array": lambda: isinstance(v, list),
        "string": lambda: isinstance(v, str),
        "number": lambda: isinstance(v, (int, float)) and not isinstance(v, bool),
        "integer": lambda: isinstance(v, int) and not isinstance(v, bool),
        "boolean": lambda: isinstance(v, bool),
        "null": lambda: v is None,
    }[t]()


def parse_frontmatter(text: str):
    """Parse a simple YAML frontmatter block (--- ... ---). Returns (dict, body).
    Supports scalars, [inline, lists] and simple 'key: value' pairs only — enough for
    SKILL.md / agent .md validation without a YAML dependency."""
    m = re.match(r"\A---\s*\n(.*?)\n---\s*\n?(.*)\Z", text, re.S)
    if not m:
        return {}, text
    data = {}
    for line in m.group(1).splitlines():
        if not line.strip() or line.startswith("#") or line.startswith(" "):
            continue
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        v = v.strip()
        if v.startswith("[") and v.endswith("]"):
            v = [x.strip().strip("'\"") for x in v[1:-1].split(",") if x.strip()]
        else:
            v = v.strip("'\"")
        data[k.strip()] = v
    return data, m.group(2)
