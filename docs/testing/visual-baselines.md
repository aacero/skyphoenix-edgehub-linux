# Visual baseline gate

The composed QML suite produces more than one thousand screenshots. The
committed review set deliberately keeps one portrait `1x1` reference for each
of the 30 widgets and one complete screen for each of the 20 presets. This makes
visual review finite while the normal GUI assertions continue to exercise all
supported sizes, orientations, states, settings, accents, and backdrops.

The source list and anti-vacuity counts live in
`tests/visual/cases.json`. Reviewed PNGs and their commit-keyed hash manifest
live in `tests/visual/baselines/`.

Compare a fresh composed run:

```bash
python3 scripts/visual_baselines.py compare
```

The comparison requires a clean committed tree. It verifies every source and
baseline exists, dimensions match, the baseline still matches its manifest
hash, and the blurred pixel delta stays within the declared limits. Blurring
only removes subpixel text-rendering noise between supported Qt renderers.
Geometry, spacing, hierarchy, surfaces, and meaningful color changes remain
visible. The GUI runner also writes the source SHA and dirty-state markers into
the evidence directory; stale or dirty screenshots are rejected. Failure diffs
are written below `artifacts/`.

Some QtTest image objects save the full test window even when their pixel API is
scoped to one offset widget. Those cases declare an explicit crop rectangle in
`cases.json`, and the same rectangle is hash-pinned in the manifest. This keeps
the comparison sensitive to the intended widget instead of unrelated whitespace
or sibling harnesses.

Update only after a person reviews the fresh screenshots:

```bash
python3 scripts/visual_baselines.py update
git add tests/visual/baselines
git commit -m "test: refresh reviewed visual baselines"
```

An update is never automatic. A changed picture is a review request, not a new
truth source.
