#!/usr/bin/env python3
# qml_coverage.py - QML behavior-matrix coverage analyzer (read-only, stdlib only).
#
# There is no trustworthy line-coverage tool for QML, so we treat QML coverage as
# a *behavior traceability matrix*: enumerate the behaviors the source exposes
# (functions, config-schema field ids, widget types, background/wallpaper catalog
# entries) and count how many are claimed-and-backed by a `tst_*.qml` test.
#
# A test file claims behaviors via a header convention:
#     // COVERS: fn:Dashboard.cfgAction, schema:clock.showSeconds, widget:cpu
# A claim is only honored if the file actually asserts: the claimed id's leaf
# token must appear inside an assertion call (compare/verify/tryCompare/
# tryVerify/fuzzyCompare) in that same file. Unbacked claims are rejected so a
# test cannot inflate coverage by merely declaring a header with no real check.
#
# One narrow extra form is honored: a COLLECTION claim `widget:*`, `schema:*`,
# `bg:*`, or `wallpaper:*`. A test that genuinely iterates the whole catalog under assertion
# (instantiates the catalog, asserts its full `.length`, and loops over that same
# collection) exercises EVERY entry, so such a claim credits every enumerated id
# of that kind. This is restricted to the three catalogs and still requires a real
# iteration+assertion - it is NOT a blanket pass, and only these catalog-backed
# `*` kinds are recognised (`fn:*`, etc. are rejected as unknown collections).
#
# Run `python3 scripts/qml_coverage.py --selftest` to verify the honesty
# guarantees (reject-unknown-id, reject-unbacked-claim, credit-backed-claim, and
# the collection rules) independently of the repository's own test files.
#
# Exit 0 if covered/total >= THRESHOLD, else exit 1. Read-only: never writes.

import os
import re
import sys

# The beta freeze criterion is stricter than line coverage: every enumerated QML
# behavior must retain an assertion-backed claim. This is a completeness matrix,
# so accepting a known gap at release time would defeat its purpose.
THRESHOLD = 100.0

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# Source files whose top-level `function name(...)` declarations are behaviors.
FUNCTION_SOURCES = [
    "ui/qml/Dashboard.qml",
    "ui/qml/main.qml",
    "ui/qml/DashboardStore.qml",
    "ui/qml/PresetCatalog.qml",
    # The size vocabulary: the single definition of what "1x1" means and how it
    # maps onto a rotated screen. Every widget's layout will key off it, so each
    # function must earn an explicit COVERS claim.
    "ui/qml/WidgetSizes.qml",
    # The placement authority that replaced GridLayout: where every tile on every
    # page ends up, and the reason a rotation re-projects instead of reshuffling.
    # Nothing else may decide geometry, so every function must earn a claim.
    "ui/qml/WidgetPacker.qml",
    # The egress gate: the one place a QML XMLHttpRequest may be built, and now
    # the one place credential refs are resolved. It is the choke point the
    # "no telemetry / local-only" claim rests on, so every function in it should
    # have to earn an explicit COVERS claim.
    "ui/qml/widgets/NetHub.qml",
    "manager/qml/Manager.qml",
    "manager/qml/EdgeClone.qml",
]
SCHEMA_SOURCE = "ui/qml/WidgetConfigSchema.qml"
WIDGET_CATALOG = "ui/qml/WidgetCatalog.qml"
BACKGROUND_CATALOG = "ui/qml/BackgroundCatalog.qml"
WALLPAPER_CATALOG = "ui/qml/WallpaperCatalog.qml"
TESTS_DIR = "tests/ui"

FUNCTION_RE = re.compile(r"\bfunction\s+(\w+)\s*\(")
SCHEMA_KEY_RE = re.compile(r'\bkey\s*:\s*"([^"]+)"')
SCHEMA_CASE_RE = re.compile(r'\bcase\s+"([^"]+)"\s*:')
WIDGET_TYPE_RE = re.compile(r'\btype\s*:\s*"([^"]+)"')
CATALOG_V_RE = re.compile(r'\bv\s*:\s*"([^"]+)"')
CATALOG_NAME_RE = re.compile(r'\bname\s*:\s*"([^"]+)"')
COVERS_RE = re.compile(r'//\s*COVERS:\s*(.+)')
ASSERT_RE = re.compile(r"\b(?:compare|verify|tryCompare|tryVerify|fuzzyCompare)\b")

# Catalogs whose full, asserted iteration credits every entry id via a `<kind>:*`
# collection claim. Value = (catalog component name, collection property name).
COLLECTION_CATALOGS = {
    "widget": ("WidgetCatalog", "items"),
    "bg": ("BackgroundCatalog", "styles"),
    "wallpaper": ("WallpaperCatalog", "items"),
}


def read(path):
    full = os.path.join(REPO, path)
    try:
        with open(full, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def component_name(path):
    return os.path.splitext(os.path.basename(path))[0]


def verify_sources():
    """Every declared source must exist, or the matrix lies.

    `read()` swallows OSError and returns "" - so a renamed, moved or typo'd path
    silently drops that file's behaviors from the matrix. It does not show up as a
    coverage DROP either: the file's UNCOVERED behaviors disappear from the
    denominator right along with its covered ones, so the ratio can happily stay
    100%.

    Measured 2026-07-17: pointing FUNCTION_SOURCES[0] at a typo'd path removed 24
    behaviors from the matrix and nothing complained. This is the same born-inert
    shape as coverage.sh's C++ gate (which skipped itself for years) and the
    QtTest `_data` trap (three tests that never ran).
    """
    declared = list(FUNCTION_SOURCES) + [
        SCHEMA_SOURCE, WIDGET_CATALOG, BACKGROUND_CATALOG, WALLPAPER_CATALOG,
    ]
    missing = [p for p in declared if not os.path.isfile(os.path.join(REPO, p))]
    if missing:
        print("FAIL: declared behavior source(s) missing - the matrix would silently")
        print("      shrink and still report a high ratio:")
        for p in missing:
            print("        %s" % p)
        return False
    if not os.path.isdir(os.path.join(REPO, TESTS_DIR)):
        print("FAIL: tests dir missing: %s" % TESTS_DIR)
        return False
    return True


def enumerate_behaviors():
    """Return an ordered list of unique behavior ids the source exposes."""
    behaviors = []
    seen = set()

    def add(bid):
        if bid not in seen:
            seen.add(bid)
            behaviors.append(bid)

    # 1. QML functions in orchestrators / store / manager.
    for src in FUNCTION_SOURCES:
        comp = component_name(src)
        for name in FUNCTION_RE.findall(read(src)):
            add("fn:%s.%s" % (comp, name))

    # 2. Config-schema fields. Per-widget identity is load-bearing: showHistory
    # on CPU, GPU and Memory is three contracts, not one globally covered key.
    # Shared title/appearance helpers are effective fields on every widget, so
    # they are scoped to every widget too.
    schema_text = read(SCHEMA_SOURCE)
    schema_switch_at = schema_text.find("function _schemaFor")
    shared_text = schema_text[:schema_switch_at] if schema_switch_at >= 0 else ""
    shared_keys = SCHEMA_KEY_RE.findall(shared_text)

    cases = list(SCHEMA_CASE_RE.finditer(schema_text))
    for index, match in enumerate(cases):
        wtype = match.group(1)
        end = cases[index + 1].start() if index + 1 < len(cases) else len(schema_text)
        for key in shared_keys:
            add("schema:%s.%s" % (wtype, key))
        for key in SCHEMA_KEY_RE.findall(schema_text[match.end():end]):
            add("schema:%s.%s" % (wtype, key))

    # 3. Widget types from the catalog.
    for wtype in WIDGET_TYPE_RE.findall(read(WIDGET_CATALOG)):
        add("widget:%s" % wtype)

    # 4. Background catalog entries.
    for v in CATALOG_V_RE.findall(read(BACKGROUND_CATALOG)):
        add("bg:%s" % v)

    # 5. Wallpaper catalog entries.
    for name in CATALOG_NAME_RE.findall(read(WALLPAPER_CATALOG)):
        add("wallpaper:%s" % name)

    return behaviors


def leaf_token(bid):
    """The significant identifier of a behavior id, used to prove backing."""
    body = bid.split(":", 1)[1] if ":" in bid else bid
    return body.split(".")[-1]


def assertion_text(text):
    """Concatenated text of every line that contains an assertion call."""
    lines = [ln for ln in text.splitlines() if ASSERT_RE.search(ln)]
    return "\n".join(lines)


def _iterates_catalog(text, comp, coll):
    """True when a file genuinely iterates the WHOLE catalog under assertion: it
    instantiates the catalog component, asserts the collection's full `.length`,
    and loops over that same collection. Together these mean every entry is
    exercised (a malformed/missing entry would fail the loop), so each entry id
    is fairly credited. This is deliberately narrow - it is not a token match."""
    if comp not in text:
        return False
    asserts = assertion_text(text)
    size_asserted = re.search(r"\.%s\.length\b" % re.escape(coll), asserts) is not None
    loops_collection = re.search(
        r"for\s*\([^)]*\.%s\.length\b" % re.escape(coll), text) is not None
    return size_asserted and loops_collection


def _iterates_scoped_schema(text):
    """True only for a test that walks every catalog widget and every effective
    schema field, constructs a widget-scoped identity, and asserts it."""
    if "WidgetCatalog" not in text or "WidgetConfigSchema" not in text:
        return False
    asserts = assertion_text(text)
    catalog_asserted = re.search(r"\.items\.length\b", asserts) is not None
    schema_asserted = "schemaFor" in asserts or "scoped" in asserts
    loops_widgets = re.search(r"for\s*\([^)]*\.items\.length\b", text) is not None
    loops_fields = re.search(r"for\s*\([^)]*\.fields\.length\b", text) is not None
    return catalog_asserted and schema_asserted and loops_widgets and loops_fields


def credit_file(text, valid_ids):
    """
    Credit the COVERS claims in a single file's text.
    Returns (covered_set, rejected_list) where rejected_list is [(claim, reason)].
    A claim is honored only if backed:
      • `<kind>:*` (kind ∈ COLLECTION_CATALOGS) → credits every enumerated id of
        that kind, but only when the file really iterates that catalog under
        assertion; otherwise it is rejected.
      • any other id → honored only if it is a known id AND its leaf token appears
        inside an assertion call in the same file; else rejected.
    """
    covered = set()
    rejected = []
    claims = []
    for m in COVERS_RE.finditer(text):
        for token in m.group(1).split(","):
            token = token.strip()
            if token:
                claims.append(token)
    if not claims:
        return covered, rejected
    asserts = assertion_text(text)
    for claim in claims:
        # Collection claim: `<kind>:*`.
        if claim.endswith(":*"):
            kind = claim[:-2]
            if kind == "schema":
                if _iterates_scoped_schema(text):
                    for b in valid_ids:
                        if b.startswith("schema:"):
                            covered.add(b)
                else:
                    rejected.append((claim, "no scoped schema catalog iteration"))
                continue
            if kind not in COLLECTION_CATALOGS:
                rejected.append((claim, "unknown collection"))
                continue
            comp, coll = COLLECTION_CATALOGS[kind]
            if _iterates_catalog(text, comp, coll):
                for b in valid_ids:
                    if b.startswith(kind + ":"):
                        covered.add(b)
            else:
                rejected.append((claim, "no backing catalog iteration"))
            continue
        # Single-id claim.
        if claim not in valid_ids:
            rejected.append((claim, "unknown behavior id"))
            continue
        needle = leaf_token(claim)
        if needle and re.search(r"\b%s\b" % re.escape(needle), asserts):
            covered.add(claim)
        else:
            rejected.append((claim, "no backing assertion"))
    return covered, rejected


def enumerate_covered(valid_ids):
    """
    Return (covered_ids, rejected) by scanning tst_*.qml COVERS headers.
    Unknown ids and unbacked claims are rejected (see credit_file).
    """
    covered = set()
    rejected = []  # (file, claimed_id, reason)
    tests_path = os.path.join(REPO, TESTS_DIR)
    if not os.path.isdir(tests_path):
        return covered, rejected

    for fname in sorted(os.listdir(tests_path)):
        if not (fname.startswith("tst_") and fname.endswith(".qml")):
            continue
        text = read(os.path.join(TESTS_DIR, fname))
        file_covered, file_rejected = credit_file(text, valid_ids)
        covered |= file_covered
        for claim, reason in file_rejected:
            rejected.append((fname, claim, reason))
    return covered, rejected


def selftest():
    """Verify the honesty guarantees on synthetic inputs (no repo files)."""
    valid = {"fn:A.foo", "schema:cpu.showHistory", "schema:gpu.showHistory",
             "widget:cpu", "widget:gpu", "bg:none", "bg:orbs"}
    checks = []

    def check(desc, cond):
        checks.append((desc, cond))

    # 1. A backed single-id claim is credited.
    cov, rej = credit_file('// COVERS: fn:A.foo\ncompare(x.foo(), 1)', valid)
    check("backed claim credited", cov == {"fn:A.foo"} and not rej)

    # 2. An unbacked single-id claim (no assertion mentions the leaf) is rejected.
    cov, rej = credit_file('// COVERS: fn:A.foo\nx.foo()\ncompare(y, 1)', valid)
    check("unbacked claim rejected", not cov and rej == [("fn:A.foo", "no backing assertion")])

    # 3. An unknown id is rejected even if its token appears in an assertion.
    cov, rej = credit_file('// COVERS: fn:A.bar\ncompare(x.bar(), 1)', valid)
    check("unknown id rejected", not cov and rej == [("fn:A.bar", "unknown behavior id")])

    # 4. A collection claim IS credited when the catalog is genuinely iterated.
    iter_txt = ('// COVERS: widget:*\n'
                'WidgetCatalog { id: c }\n'
                'compare(c.items.length, 2)\n'
                'for (var i = 0; i < c.items.length; i++) verify(c.items[i].type)\n')
    cov, rej = credit_file(iter_txt, valid)
    check("collection credited on real iteration",
          cov == {"widget:cpu", "widget:gpu"} and not rej)

    # 5. A collection claim is REJECTED without a real iteration (no blanket pass).
    cov, rej = credit_file('// COVERS: widget:*\nverify(true)', valid)
    check("collection rejected without iteration",
          not cov and rej == [("widget:*", "no backing catalog iteration")])

    # 6. An unknown collection kind is rejected (only the 3 catalogs qualify).
    cov, rej = credit_file('// COVERS: fn:*\ncompare(a.b.length, 1)', valid)
    check("unknown collection rejected", not cov and rej == [("fn:*", "unknown collection")])

    # 7. A collection claim for one kind must not leak into another kind.
    cov, rej = credit_file(iter_txt, valid)
    check("collection scoped to its kind", "bg:none" not in cov and "bg:orbs" not in cov)

    # 8. Same-named schema fields remain widget-scoped.
    cov, rej = credit_file(
        '// COVERS: schema:cpu.showHistory\ncompare(cpu.showHistory, true)', valid)
    check("schema claim is widget scoped",
          cov == {"schema:cpu.showHistory"}
          and "schema:gpu.showHistory" not in cov and not rej)

    # 9. Schema collection claims require both catalogs and nested field loops.
    schema_iter = (
        '// COVERS: schema:*\n'
        'WidgetCatalog { id: catalog }\nWidgetConfigSchema { id: schemas }\n'
        'compare(catalog.items.length, 2)\n'
        'for (var i = 0; i < catalog.items.length; i++) {\n'
        '  var d = schemas.schemaFor(catalog.items[i].type)\n'
        '  for (var j = 0; j < d.fields.length; j++) verify(scoped)\n}\n')
    cov, rej = credit_file(schema_iter, valid)
    check("scoped schema collection credited on nested iteration",
          cov == {"schema:cpu.showHistory", "schema:gpu.showHistory"} and not rej)

    ok = all(c for _, c in checks)
    print("qml_coverage self-test")
    for desc, cond in checks:
        print("  [%s] %s" % ("PASS" if cond else "FAIL", desc))
    print("SELF-TEST %s" % ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


def main():
    if not verify_sources():
        return 1
    behaviors = enumerate_behaviors()
    valid = set(behaviors)
    total = len(behaviors)
    covered, rejected = enumerate_covered(valid)
    covered_count = len(covered)
    # An empty matrix is a broken matrix, never a perfect one. This used to read
    # `if total else 100.0`, i.e. "found nothing -> 100% -> PASS".
    if total == 0:
        print("FAIL: the behavior matrix enumerated ZERO behaviors.")
        print("      That is a broken scan, not perfect coverage.")
        return 1
    ratio = 100.0 * covered_count / total

    uncovered = [b for b in behaviors if b not in covered]

    print("QML behavior-matrix coverage")
    print("  behaviors enumerated : %d" % total)
    print("  behaviors covered    : %d" % covered_count)
    print("  ratio                : %.1f%% (gate >= %.0f%%)" % (ratio, THRESHOLD))

    if rejected:
        print("\nRejected COVERS claims (%d):" % len(rejected))
        for fname, claim, reason in rejected:
            print("  %-32s %-40s %s" % (fname, claim, reason))

    if uncovered:
        print("\nUncovered behaviors (%d):" % len(uncovered))
        for b in uncovered:
            print("  %s" % b)

    if ratio < THRESHOLD:
        print("\nFAIL: QML behavior coverage %.1f%% < %.0f%%" % (ratio, THRESHOLD))
        return 1
    print("\nPASS: QML behavior coverage %.1f%% >= %.0f%%" % (ratio, THRESHOLD))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(main())
