#!/usr/bin/env python3
"""Fail when WidgetCatalog, Hub resources, and Manager resources diverge."""

from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "ui/qml/WidgetCatalog.qml"
HUB_QRC = ROOT / "ui/qml.qrc"
MANAGER_QRC = ROOT / "manager/manager.qrc"


def catalog_widgets():
    text = CATALOG.read_text(encoding="utf-8")
    pairs = re.findall(
        r'\{\s*type:\s*"([^"]+)".*?source:\s*"qrc:/qml/([^"]+Widget\.qml)"',
        text,
        re.DOTALL,
    )
    result = {}
    for widget_type, filename in pairs:
        if widget_type in result:
            raise ValueError(f"duplicate catalog type: {widget_type}")
        result[widget_type] = filename
    if len(result) < 30:
        raise ValueError(f"catalog parse found only {len(result)} widgets")
    return result


def aliases(path):
    root = ET.parse(path).getroot()
    values = []
    for element in root.iter("file"):
        alias = element.attrib.get("alias", element.text or "").strip()
        values.append(alias)
    return values


def main():
    try:
        catalog = catalog_widgets()
        hub = aliases(HUB_QRC)
        manager = aliases(MANAGER_QRC)
    except (OSError, ET.ParseError, ValueError) as error:
        print(f"RESOURCE PARITY FAILED: {error}")
        return 1

    expected_hub = {f"qml/{filename}" for filename in catalog.values()}
    expected_manager = set(catalog.values())
    actual_hub = {alias for alias in hub if alias.startswith("qml/") and alias.endswith("Widget.qml")}
    actual_manager = {alias for alias in manager if "/" not in alias and alias.endswith("Widget.qml")}

    problems = []
    for alias in sorted(expected_hub - actual_hub):
        problems.append(f"Hub is missing {alias}")
    for alias in sorted(actual_hub - expected_hub):
        problems.append(f"Hub has uncataloged widget resource {alias}")
    for alias in sorted(expected_manager - actual_manager):
        problems.append(f"Manager is missing {alias}")
    for alias in sorted(actual_manager - expected_manager):
        problems.append(f"Manager has uncataloged widget resource {alias}")

    for widget_type, filename in sorted(catalog.items()):
        source = ROOT / "ui/qml/widgets" / filename
        if not source.is_file():
            problems.append(f"{widget_type} source is missing: {source.relative_to(ROOT)}")
        if hub.count(f"qml/{filename}") != 1:
            problems.append(f"Hub must register {filename} exactly once")
        if manager.count(filename) != 1:
            problems.append(f"Manager must register {filename} exactly once")

    if problems:
        print("RESOURCE PARITY FAILED:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(
        f"RESOURCE PARITY PASSED: {len(catalog)} catalog widgets match Hub and Manager"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
