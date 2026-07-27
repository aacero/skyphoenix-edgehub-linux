#!/usr/bin/env python3
"""Build and validate the exact release CycloneDX 1.5 document.

The caller supplies immutable snapshot files plus their independently recorded
digest and size. Imported references are namespaced and the completed graph is
validated before any output is published.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import pathlib
import re
import sys
import uuid
from typing import Any


REFERENCE_KEYS = {"bom-ref", "ref"}
REFERENCE_LIST_KEYS = {"assemblies", "dependencies", "dependsOn"}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
FULL_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
CONSERVATIVE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
COMPONENT_TYPES = {
    "application",
    "container",
    "cryptographic-asset",
    "data",
    "device",
    "device-driver",
    "file",
    "firmware",
    "framework",
    "library",
    "machine-learning-model",
    "operating-system",
    "platform",
}


def fail(message: str) -> None:
    raise ValueError(message)


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a non-empty string")
    return value


def load_bom(path: pathlib.Path, label: str) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            bom = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"{label} is not readable CycloneDX JSON: {error}")
    if not isinstance(bom, dict):
        fail(f"{label} root must be a JSON object")
    if bom.get("bomFormat") != "CycloneDX":
        fail(f"{label} does not declare bomFormat CycloneDX")
    if bom.get("specVersion") != "1.5":
        fail(f"{label} must be CycloneDX 1.5")
    if not isinstance(bom.get("metadata"), dict):
        fail(f"{label} has no metadata object")
    if not isinstance(bom["metadata"].get("component"), dict):
        fail(f"{label} has no metadata.component")
    if not isinstance(bom.get("components", []), list):
        fail(f"{label} components must be an array")
    if not isinstance(bom.get("dependencies", []), list):
        fail(f"{label} dependencies must be an array")
    return bom


def namespace_bom_refs(value: Any, prefix: str) -> Any:
    """Deep-copy a CycloneDX fragment and namespace graph references."""

    if isinstance(value, list):
        return [namespace_bom_refs(item, prefix) for item in value]
    if not isinstance(value, dict):
        return copy.deepcopy(value)

    result: dict[str, Any] = {}
    for key, item in value.items():
        if key in REFERENCE_KEYS and isinstance(item, str):
            result[key] = f"{prefix}{item}"
        elif key in REFERENCE_LIST_KEYS and isinstance(item, list):
            result[key] = [
                f"{prefix}{entry}"
                if isinstance(entry, str)
                else namespace_bom_refs(entry, prefix)
                for entry in item
            ]
        else:
            result[key] = namespace_bom_refs(item, prefix)
    return result


def ensure_bom_ref(component: dict[str, Any], generated_ref: str) -> str:
    reference = component.get("bom-ref")
    if not isinstance(reference, str) or not reference:
        component["bom-ref"] = generated_ref
        return generated_ref
    return reference


def add_source_property(component: dict[str, Any], name: str, value: str) -> None:
    properties = component.setdefault("properties", [])
    if not isinstance(properties, list):
        fail(f"component {component.get('name', '<unnamed>')} has non-array properties")
    properties.append({"name": name, "value": value})


def import_bom(
    bom: dict[str, Any],
    namespace: str,
    source_property: str,
    *,
    inventory_root_links_all: bool,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], str, list[dict[str, Any]]]:
    prefix = f"{namespace}:"
    root = namespace_bom_refs(bom["metadata"]["component"], prefix)
    root_ref = ensure_bom_ref(root, f"{prefix}root")
    add_source_property(root, "edgehub:sbom:component-source", source_property)

    components: list[dict[str, Any]] = [root]
    child_refs: list[str] = []
    for index, raw_component in enumerate(bom.get("components", [])):
        if not isinstance(raw_component, dict):
            fail(f"{source_property} component {index} is not an object")
        component = namespace_bom_refs(raw_component, prefix)
        child_ref = ensure_bom_ref(component, f"{prefix}component:{index}")
        child_refs.append(child_ref)
        add_source_property(component, "edgehub:sbom:component-source", source_property)
        components.append(component)

    dependencies: list[dict[str, Any]] = []
    for index, raw_dependency in enumerate(bom.get("dependencies", [])):
        if not isinstance(raw_dependency, dict):
            fail(f"{source_property} dependency {index} is not an object")
        dependencies.append(namespace_bom_refs(raw_dependency, prefix))

    # Syft is an inventory tool, not a dependency resolver for every cataloger.
    # Connect every item it found to that scan's root so the release graph says
    # "this artifact contains these discoveries" without inventing package to
    # package edges.
    if inventory_root_links_all:
        root_dependency = next(
            (item for item in dependencies if item.get("ref") == root_ref), None
        )
        if root_dependency is None:
            root_dependency = {"ref": root_ref, "dependsOn": []}
            dependencies.append(root_dependency)
        depends_on = root_dependency.setdefault("dependsOn", [])
        if not isinstance(depends_on, list):
            fail(f"{source_property} root dependency has non-array dependsOn")
        for child_ref in child_refs:
            if child_ref not in depends_on:
                depends_on.append(child_ref)

    tools = bom["metadata"].get("tools", [])
    if isinstance(tools, dict):
        tools = tools.get("components", [])
    if not isinstance(tools, list):
        tools = []
    return components, dependencies, root_ref, copy.deepcopy(tools)


def artifact_media_type(name: str) -> str:
    if name.endswith(".AppImage"):
        return "application/vnd.appimage"
    if name.endswith(".deb"):
        return "application/vnd.debian.binary-package"
    if name.endswith(".rpm"):
        return "application/x-rpm"
    if name.endswith(".pkg.tar.zst"):
        return "application/zstd"
    if name.endswith(".tar.gz"):
        return "application/gzip"
    if name.endswith(".zsync"):
        return "application/x-zsync"
    if name.endswith(".md"):
        return "text/markdown"
    return "application/octet-stream"


def normalize_tool_components(tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Represent both legacy Tool entries and modern tool components safely."""

    normalized: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, raw_tool in enumerate(tools):
        if not isinstance(raw_tool, dict):
            continue
        if raw_tool.get("type") in COMPONENT_TYPES:
            component = copy.deepcopy(raw_tool)
        else:
            name = raw_tool.get("name")
            if not isinstance(name, str) or not name:
                continue
            component = {"type": "application", "name": name}
            vendor = raw_tool.get("vendor")
            version = raw_tool.get("version")
            if isinstance(vendor, str) and vendor:
                component["group"] = vendor
            if isinstance(version, str) and version:
                component["version"] = version
            for key in ("hashes", "externalReferences"):
                if key in raw_tool:
                    component[key] = copy.deepcopy(raw_tool[key])
        component.pop("bom-ref", None)
        component["bom-ref"] = (
            "release-tool:"
            + hashlib.sha256(
                json.dumps(component, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest()
        )
        marker = json.dumps(component, sort_keys=True, separators=(",", ":"))
        if marker not in seen:
            seen.add(marker)
            normalized.append(component)
    return normalized


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_properties(properties: Any, label: str) -> None:
    if properties is None:
        return
    if not isinstance(properties, list):
        fail(f"{label}.properties must be an array")
    names: set[str] = set()
    for index, prop in enumerate(properties):
        if not isinstance(prop, dict):
            fail(f"{label}.properties[{index}] must be an object")
        name = require_string(prop.get("name"), f"{label}.properties[{index}].name")
        require_string(prop.get("value"), f"{label}.properties[{index}].value")
        if name in names:
            fail(f"{label} has duplicate property name: {name}")
        names.add(name)


def validate_component(component: Any, label: str) -> str:
    if not isinstance(component, dict):
        fail(f"{label} must be an object")
    component_type = require_string(component.get("type"), f"{label}.type")
    if component_type not in COMPONENT_TYPES:
        fail(f"{label}.type is not a CycloneDX 1.5 component type: {component_type}")
    reference = require_string(component.get("bom-ref"), f"{label}.bom-ref")
    require_string(component.get("name"), f"{label}.name")
    validate_properties(component.get("properties"), label)
    hashes = component.get("hashes")
    if hashes is not None:
        if not isinstance(hashes, list) or not hashes:
            fail(f"{label}.hashes must be a non-empty array when present")
        for index, item in enumerate(hashes):
            if not isinstance(item, dict):
                fail(f"{label}.hashes[{index}] must be an object")
            if item.get("alg") == "SHA-256" and not SHA256_RE.fullmatch(
                str(item.get("content", ""))
            ):
                fail(f"{label}.hashes[{index}] has an invalid SHA-256 digest")
    return reference


def validate_graph(document: dict[str, Any]) -> None:
    """Validate the generated CycloneDX 1.5 release profile and graph."""

    if document.get("$schema") != "http://cyclonedx.org/schema/bom-1.5.schema.json":
        fail("generated SBOM does not pin the CycloneDX 1.5 JSON schema")
    if document.get("bomFormat") != "CycloneDX" or document.get("specVersion") != "1.5":
        fail("generated SBOM identity is not CycloneDX 1.5")
    if document.get("version") != 1:
        fail("generated SBOM version must be 1")
    serial = require_string(document.get("serialNumber"), "serialNumber")
    if not serial.startswith("urn:uuid:"):
        fail("serialNumber must use a UUID URN")

    metadata = document.get("metadata")
    if not isinstance(metadata, dict):
        fail("metadata must be an object")
    root_ref = validate_component(metadata.get("component"), "metadata.component")
    require_string(metadata.get("timestamp"), "metadata.timestamp")
    tool_block = metadata.get("tools")
    if not isinstance(tool_block, dict):
        fail("metadata.tools must use the CycloneDX 1.5 component form")
    tool_components = tool_block.get("components")
    if not isinstance(tool_components, list) or not tool_components:
        fail("metadata.tools.components must be a non-empty array")
    tool_refs: set[str] = set()
    for index, component in enumerate(tool_components):
        reference = validate_component(
            component, f"metadata.tools.components[{index}]"
        )
        if reference in tool_refs:
            fail(f"duplicate tool bom-ref: {reference}")
        tool_refs.add(reference)

    raw_components = document.get("components")
    if not isinstance(raw_components, list) or not raw_components:
        fail("components must be a non-empty array")
    refs = {root_ref}
    for index, component in enumerate(raw_components):
        reference = validate_component(component, f"components[{index}]")
        if reference in refs:
            fail(f"duplicate bom-ref: {reference}")
        refs.add(reference)

    raw_dependencies = document.get("dependencies")
    if not isinstance(raw_dependencies, list) or not raw_dependencies:
        fail("dependencies must be a non-empty array")
    dependency_map: dict[str, list[str]] = {}
    for index, dependency in enumerate(raw_dependencies):
        if not isinstance(dependency, dict):
            fail(f"dependencies[{index}] must be an object")
        reference = require_string(dependency.get("ref"), f"dependencies[{index}].ref")
        if reference not in refs:
            fail(f"dependency source does not resolve: {reference}")
        if reference in dependency_map:
            fail(f"duplicate dependency graph entry: {reference}")
        targets = dependency.get("dependsOn", [])
        if not isinstance(targets, list):
            fail(f"dependency {reference} has non-array dependsOn")
        if len(targets) != len(set(targets)):
            fail(f"dependency {reference} has duplicate targets")
        for target in targets:
            if not isinstance(target, str) or target not in refs:
                fail(f"dependency target does not resolve: {target!r}")
            if target == reference:
                fail(f"dependency graph contains a self-edge: {reference}")
        dependency_map[reference] = targets

    # Every component must be connected to the release root. A syntactically
    # valid array of orphaned packages is not release composition evidence.
    reachable = {root_ref}
    pending = [root_ref]
    while pending:
        current = pending.pop()
        for target in dependency_map.get(current, []):
            if target not in reachable:
                reachable.add(target)
                pending.append(target)
    orphaned = refs - reachable
    if orphaned:
        fail(f"dependency graph contains unreachable bom-ref: {sorted(orphaned)[0]}")

    compositions = document.get("compositions")
    if not isinstance(compositions, list) or len(compositions) != 2:
        fail("release SBOM must contain the payload and dependency compositions")
    for index, composition in enumerate(compositions):
        if not isinstance(composition, dict):
            fail(f"compositions[{index}] must be an object")
        if composition.get("aggregate") not in {
            "complete",
            "incomplete",
            "incomplete_first_party_only",
            "incomplete_third_party_only",
            "unknown",
            "not_specified",
        }:
            fail(f"compositions[{index}] has an invalid aggregate")
        for key in ("assemblies", "dependencies"):
            values = composition.get(key, [])
            if not isinstance(values, list):
                fail(f"compositions[{index}].{key} must be an array")
            for reference in values:
                if not isinstance(reference, str) or reference not in refs:
                    fail(f"composition reference does not resolve: {reference!r}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-date-epoch", required=True, type=int)
    parser.add_argument("--mode", choices=("complete", "fallback"), required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--tag-object", required=True)
    parser.add_argument("--signing-key", required=True)
    parser.add_argument("--cargo-tool-version", required=True)
    parser.add_argument("--syft-tool-version", required=True)
    parser.add_argument("--cargo-bom", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument(
        "--artifact",
        action="append",
        nargs=5,
        metavar=("DISPLAY_PATH", "SNAPSHOT_PATH", "SYFT_BOM_OR_NONE", "SHA256", "SIZE"),
        default=[],
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.artifact:
        fail("at least one release artifact is required")
    if args.source_date_epoch < 0:
        fail("source date epoch must not be negative")
    if not FULL_COMMIT_RE.fullmatch(args.source_commit):
        fail("source commit must be a full 40-character lowercase object id")
    if not FULL_COMMIT_RE.fullmatch(args.tag_object):
        fail("tag object must be a full 40-character lowercase object id")
    if not FULL_COMMIT_RE.fullmatch(args.signing_key):
        fail("signing key must be a full 40-character lowercase fingerprint")

    cargo_bom = load_bom(args.cargo_bom, "Cargo SBOM")
    cargo_raw_components = cargo_bom.get("components", [])
    if len(cargo_raw_components) < 10:
        fail(
            "Cargo SBOM anti-vacuity floor failed: "
            f"expected at least 10 components, found {len(cargo_raw_components)}"
        )
    components, dependencies, cargo_root_ref, tools = import_bom(
        cargo_bom,
        "cargo",
        "cargo-cyclonedx",
        inventory_root_links_all=False,
    )

    artifact_components: list[dict[str, Any]] = []
    dependency_roots = [cargo_root_ref]
    seen_names: set[str] = set()
    identity_parts = [
        args.version,
        args.mode,
        args.source_commit,
        args.tag_object,
        args.signing_key,
    ]
    syft_scan_count = 0
    syft_discovery_count = 0

    for index, artifact_values in enumerate(args.artifact):
        artifact_text, snapshot_text, scan_text, expected_digest, size_text = artifact_values
        artifact = pathlib.Path(artifact_text)
        snapshot = pathlib.Path(snapshot_text)
        if not snapshot.is_file():
            fail(f"release artifact snapshot is not a regular file: {snapshot}")
        name = artifact.name
        if (
            not CONSERVATIVE_NAME_RE.fullmatch(name)
            or name.startswith(".")
            or ".." in name
            or "#" in name
        ):
            fail(f"release artifact has a non-portable basename: {name!r}")
        if name in seen_names:
            fail(f"duplicate release artifact basename: {name}")
        seen_names.add(name)
        if not SHA256_RE.fullmatch(expected_digest):
            fail(f"invalid expected SHA-256 for {name}")
        try:
            expected_size = int(size_text)
        except ValueError:
            fail(f"invalid expected size for {name}: {size_text!r}")
        if expected_size < 0:
            fail(f"expected size must not be negative for {name}")

        actual_digest = sha256(snapshot)
        actual_size = snapshot.stat().st_size
        if actual_digest != expected_digest or actual_size != expected_size:
            fail(f"sealed artifact snapshot identity changed: {name}")
        identity_parts.extend((name, expected_digest, str(expected_size)))
        artifact_ref = f"release-artifact:{index}:{expected_digest}"
        artifact_component = {
            "type": "file",
            "bom-ref": artifact_ref,
            "name": name,
            "version": args.version,
            "hashes": [{"alg": "SHA-256", "content": expected_digest}],
            "properties": [
                {"name": "edgehub:release-artifact", "value": "true"},
                {"name": "edgehub:media-type", "value": artifact_media_type(name)},
                {"name": "edgehub:size-bytes", "value": str(expected_size)},
                {"name": "edgehub:source-commit", "value": args.source_commit},
            ],
        }
        artifact_components.append(artifact_component)

        if scan_text == "NONE":
            if args.mode == "complete":
                fail(f"complete mode has no Syft inventory for {name}")
            continue

        scan_path = pathlib.Path(scan_text)
        scan_bom = load_bom(scan_path, f"Syft SBOM for {name}")
        imported, imported_dependencies, root_ref, imported_tools = import_bom(
            scan_bom,
            f"syft-{index}",
            f"syft:{name}",
            inventory_root_links_all=True,
        )
        add_source_property(artifact_component, "edgehub:syft-root-ref", root_ref)
        components.extend(imported)
        dependencies.extend(imported_dependencies)
        dependencies.append({"ref": artifact_ref, "dependsOn": [root_ref]})
        dependency_roots.append(root_ref)
        tools.extend(imported_tools)
        syft_scan_count += 1
        syft_discovery_count += len(scan_bom.get("components", []))

    if args.mode == "complete":
        if syft_scan_count != len(args.artifact):
            fail("complete mode did not import one Syft inventory per artifact")
        if syft_discovery_count == 0:
            fail("complete mode Syft scans discovered no components in any artifact")

    components = artifact_components + components
    root_ref = f"pkg:github/skyphoenix-it/skyphoenix-edgehub-linux@{args.version}"
    dependencies.append(
        {
            "ref": root_ref,
            "dependsOn": [component["bom-ref"] for component in artifact_components]
            + dependency_roots,
        }
    )

    unique_tools = normalize_tool_components(tools)
    if not unique_tools:
        fail("release SBOM has no valid tool component inventory")

    identity = "\n".join(identity_parts)
    serial = uuid.uuid5(
        uuid.NAMESPACE_URL,
        "https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/releases/"
        f"{identity}",
    )
    timestamp = dt.datetime.fromtimestamp(
        args.source_date_epoch, tz=dt.timezone.utc
    ).isoformat().replace("+00:00", "Z")
    dependency_mode = (
        "cargo-cyclonedx plus Syft for every artifact"
        if args.mode == "complete"
        else "cargo-cyclonedx plus exact artifact hashes; binary package discovery unavailable"
    )

    result = {
        "$schema": "http://cyclonedx.org/schema/bom-1.5.schema.json",
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "timestamp": timestamp,
            "tools": {"components": unique_tools},
            "component": {
                "type": "application",
                "bom-ref": root_ref,
                "group": "skyphoenix-it",
                "name": "skyphoenix-edgehub-linux",
                "version": args.version,
                "purl": root_ref,
                "properties": [
                    {"name": "edgehub:release:source-commit", "value": args.source_commit},
                    {"name": "edgehub:release:tag", "value": args.release_tag},
                    {"name": "edgehub:release:tag-object", "value": args.tag_object},
                    {
                        "name": "edgehub:release:signing-key-fingerprint",
                        "value": args.signing_key,
                    },
                    {
                        "name": "edgehub:sbom:cargo-cyclonedx-version",
                        "value": args.cargo_tool_version,
                    },
                    {"name": "edgehub:sbom:syft-version", "value": args.syft_tool_version},
                    {
                        "name": "edgehub:sbom:release-artifact-set",
                        "value": "complete",
                    },
                    {
                        "name": "edgehub:sbom:dependency-identification",
                        "value": dependency_mode,
                    },
                    {"name": "edgehub:sbom:scan-mode", "value": args.mode},
                ],
            },
        },
        "components": components,
        "dependencies": dependencies,
        "compositions": [
            {
                "aggregate": "complete",
                "assemblies": [
                    component["bom-ref"] for component in artifact_components
                ],
            },
            {
                "aggregate": "incomplete",
                "dependencies": dependency_roots,
            },
        ],
    }

    validate_graph(result)
    if args.output.exists():
        fail(f"refusing to overwrite existing SBOM: {args.output}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8", newline="\n") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
