#!/usr/bin/env python3
"""Every app that loads Theme.qml must ship the fonts Theme.qml asks for.

WHY THIS EXISTS
`fontMono` used to be the string "JetBrains Mono, Fira Code, monospace", which
Qt does NOT split into a family list - it matched the whole thing as one family
name and let fontconfig pick. The same widget rendered in real monospace on a
dev box and in a proportional sans on CI, and a proportional face in a countdown
jitters on every digit change. `fontDisplay`'s "system" option had the identical
defect, so the product's own face (Inter) was never selected anywhere. Both were
fixed on 2026-08-02 by BUNDLING the faces and resolving through a FontLoader.

That fix is held together by three files that nothing checked against each other:

    assets/fonts/*.ttf   the bytes
    assets/fonts.qrc     which bytes get compiled into a binary
    ui/qml/Theme.qml     which filenames the FontLoaders actually ask for

Drop a target's `assets/fonts.qrc` line in CMakeLists.txt and that app silently
falls back to fontconfig - exactly the pre-2026-08-02 defect. `tst_theme.qml`
does assert `monoLoader.status === FontLoader.Ready`, but it runs inside
`xeneon-qmltestrunner`, which carries its OWN fonts.qrc line. The suite would
stay green while the shipped Hub and Manager rendered the wrong faces: the guard
passes because the HARNESS has the resource, not because the PRODUCT does.

So this gate compares the three files directly, statically, with no build.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
CMAKE = ROOT / "CMakeLists.txt"
FONTS_QRC = ROOT / "assets/fonts.qrc"
FONTS_DIR = ROOT / "assets/fonts"
THEME = ROOT / "ui/qml/Theme.qml"

FONTS_QRC_REL = "assets/fonts.qrc"

# `FontLoader { source: t._fontsDir + "Inter-Regular.ttf" }`
LOADER = re.compile(r'FontLoader\s*\{\s*source:[^}]*?"([^"]+\.ttf)"')
QRC_FILE = re.compile(r'<file[^>]*?(?:alias="([^"]+)")?[^>]*>([^<]+)</file>')


def executable_targets(text):
    """Yield (target_name, body) for each add_executable(...) block."""
    for match in re.finditer(r"add_executable\(\s*([A-Za-z0-9_.-]+)", text):
        depth, index = 0, text.index("(", match.start())
        for position in range(index, len(text)):
            if text[position] == "(":
                depth += 1
            elif text[position] == ")":
                depth -= 1
                if depth == 0:
                    yield match.group(1), text[index:position]
                    break


def qrc_provides_theme(path):
    if not path.is_file():
        return False
    return "Theme.qml" in path.read_text(encoding="utf-8")


def main():
    problems = []

    for required in (CMAKE, FONTS_QRC, THEME):
        if not required.is_file():
            print(f"FAIL: {required.relative_to(ROOT)} is missing - this gate "
                  "cannot check anything.")
            return 1

    cmake_text = CMAKE.read_text(encoding="utf-8")

    # ── 1. every target that loads Theme.qml must also compile in the fonts ──
    theme_targets = 0
    targets_seen = 0
    for name, body in executable_targets(cmake_text):
        targets_seen += 1
        qrcs = re.findall(r"\$\{CMAKE_SOURCE_DIR\}/(\S+\.qrc)", body)
        loads_theme = any(qrc_provides_theme(ROOT / q) for q in qrcs)
        if not loads_theme:
            continue
        theme_targets += 1
        if FONTS_QRC_REL not in qrcs:
            problems.append(
                f"target `{name}` compiles a qrc that provides Theme.qml but "
                f"not {FONTS_QRC_REL} - its FontLoaders will fail and every "
                "readout falls back to fontconfig")

    # ── 2. Theme.qml's loaders are the real subjects: each must be bundled ──
    theme_text = THEME.read_text(encoding="utf-8")
    wanted = LOADER.findall(theme_text)

    qrc_text = FONTS_QRC.read_text(encoding="utf-8")
    bundled = {}
    for alias, target in QRC_FILE.findall(qrc_text):
        name = (alias or Path(target.strip()).name).strip()
        bundled[name] = target.strip()

    for filename in wanted:
        if filename not in bundled:
            problems.append(
                f"Theme.qml loads {filename} but {FONTS_QRC_REL} does not "
                "bundle it - the FontLoader resolves to nothing at runtime")

    # ── 3. the qrc must not promise bytes that are not there ────────────────
    for name, target in sorted(bundled.items()):
        if not (FONTS_QRC.parent / target).is_file():
            problems.append(f"{FONTS_QRC_REL} lists {target} but the file does "
                            "not exist")

    # ── 4. a face added to the directory but never bundled is invisible ─────
    on_disk = sorted(p.name for p in FONTS_DIR.glob("*.ttf"))
    for name in on_disk:
        if name not in bundled:
            problems.append(f"assets/fonts/{name} exists but is not in "
                            f"{FONTS_QRC_REL} - it will never load")

    # ── anti-vacuity floor ──────────────────────────────────────────────────
    # A gate must assert its own subjects exist, or it reports SUCCESS for the
    # state where it did no work. See BACKLOG.md "Test-integrity debt"; two
    # gates in this repo shipped with that defect and passed for months.
    blind = []
    if targets_seen == 0:
        blind.append("no add_executable() targets parsed from CMakeLists.txt")
    if theme_targets == 0:
        blind.append("no target was found to load Theme.qml - the qrc->Theme "
                     "link this gate exists to check was not seen at all")
    if not wanted:
        blind.append("no FontLoader sources parsed from Theme.qml")
    if not bundled:
        blind.append(f"no <file> entries parsed from {FONTS_QRC_REL}")
    if not on_disk:
        blind.append("no .ttf files found in assets/fonts/")
    if blind:
        print("FAIL: this gate cannot see its own subjects, so an OK from it "
              "would mean nothing:")
        for reason in blind:
            print(f"  - {reason}")
        return 1

    if problems:
        print("FAIL: the bundled-font contract is broken.")
        print("      Fonts are bundled so every machine renders the same "
              "glyphs; a break here")
        print("      is silent - text still draws, in the wrong face.")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    print(f"OK: {len(wanted)} FontLoader(s) in Theme.qml resolve to bundled "
          f"faces; {len(bundled)} file(s) in {FONTS_QRC_REL} all exist; "
          f"{len(on_disk)} .ttf on disk all bundled; "
          f"{theme_targets} Theme.qml-loading target(s) compile them in.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
