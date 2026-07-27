# Widget Manifest Specification - Tier-0 user widgets

**Status:** shipped (v1.0) · **`manifestVersion`: 1** · machine-readable schema:
[`manifest.schema.json`](manifest.schema.json)

This document specifies how a **user widget** - a widget you write yourself and
drop into a directory, without forking the hub - is packaged, discovered,
validated and loaded. It is the whole of Tier-0 extensibility:

| Tier | What it is | Status |
|---|---|---|
| **0** | A manifest + a QML file in a user directory, loaded by the hub | **this spec** |
| 1 | Scripting API with a constrained surface | post-1.0 |
| 2 | Native plugins | post-1.0 |
| 3 | WASM sandbox | post-1.0 |

Tier-0 deliberately adds **no runtime**: a user widget is plain QML speaking the
same host contract as shipped widgets ([authoring guide](authoring.md)). What
the manifest adds is *packaging*: a declared type, title, sizes and config
schema, so the hub can put your widget in the picker, size it legally, persist
its settings and render its config form - exactly like a shipped widget.

---

## The load directory

```
$XDG_DATA_HOME/xeneon-edge-hub/widgets/<your-widget>/
├── manifest.json      (required - this spec)
├── <Entry>.qml        (required - the widget, named by `entry`)
└── <icon>.svg|.png    (optional - named by `icon`)
```

`$XDG_DATA_HOME` defaults to `~/.local/share`. **One directory per widget**;
the directory name is yours to choose (only the manifest's `type` matters).
`entry` and `icon` must be plain file names in that directory - no
subdirectories, no `..`, no absolute paths.

The hub scans this directory **once at startup** (and again when a live config
push arrives from the Manager). Add or edit a widget → restart the hub (or push
from the Manager) to pick it up.

### Off by default

The scan is gated by the `enableUserWidgets` flag and **the default is
`false`**: a stock install never reads the directory and never loads user QML
(see [Security posture](#security-posture-tier-0--the-honest-version) for why).
The flag lives in the persisted UI state's `appearance` object (inside
`~/.config/xeneon-edge-hub/config.toml` → `ui_state`):

```json
"appearance": { "enableUserWidgets": true }
```

A managed/enterprise configuration can pin this flag to `false`; the hub then
neither scans nor loads, regardless of what is on disk.

The session-only `xeneon-edge-hub --safe-mode` command is an additional
fail-closed boundary: the Hub does not scan this directory and no user or
first-party widget QML is instantiated. Safe mode does not change
`enableUserWidgets`, remove tiles, or rewrite the saved layout.

---

## `manifest.json`

A complete example:

```json
{
  "manifestVersion": 1,
  "type": "user.hello",
  "title": "Hello",
  "category": "User",
  "description": "Greets someone. Set the name in config.",
  "entry": "HelloWidget.qml",
  "icon": "hello.svg",
  "sizes": ["0.5x1", "1x1", "1x1.5"],
  "dflt": "1x1",
  "defaults": { "who": "world" },
  "config": [
    { "key": "who", "label": "Name", "type": "text",
      "placeholder": "world", "dflt": "world",
      "help": "Who to greet." }
  ]
}
```

### Fields

| Field | Type | Required | Rules |
|---|---|---|---|
| `manifestVersion` | integer | **yes** | Must be exactly `1`. Anything else is skipped (a future hub may speak later versions; this one does not guess). |
| `type` | string | **yes** | The widget's unique id. **Must** match `^user\.[a-z0-9][a-z0-9_-]*$` - i.e. namespaced under `user.`. Shipped types are bare words (`cpu`, `clock`, …), so a conforming user type can never collide with one; the loader additionally rejects any collision with a shipped type outright (**shipped always wins**), and duplicate user types (first directory in name order wins). |
| `title` | string | **yes** | Non-empty. Shown in the picker, the tile header and the expanded view. |
| `entry` | string | **yes** | The widget's QML file: a plain `*.qml` file name that exists in the widget directory. |
| `sizes` | string[] | **yes** | Non-empty. Every entry must be one of the **7 legal size names** defined in `ui/qml/WidgetSizes.qml`: `0.5x0.5`, `0.5x1`, `1x0.5`, `1x1`, `1x1.5`, `1x2`, `1x3`. A size is `(short × long)` relative to the *rotating* screen - declaring one is a claim that your widget renders acceptably in **both** of its physical shapes (see WidgetSizes' header comment). Duplicates are dropped; the list is re-ordered smallest → largest. The resize button and the store only ever offer/accept declared sizes. Declaring `1x1` (the baseline) is strongly recommended. |
| `dflt` | string | no | The size a fresh instance gets. Must be listed in `sizes`. Default: `"1x1"` if declared, else the smallest declared size. |
| `category` | string | no | Picker group. Default `"User"`. You may reuse a shipped category (`System`, `Time`, `Focus`, `Media`, `Data`, `Info`) or name your own. |
| `description` | string | no | One line, shown in the expanded view header and the config panel's About section. |
| `defaults` | object | no | Seeds a fresh instance's persisted settings (same role as a catalog entry's `defaults`). Must be a JSON object. Default `{}`. |
| `icon` | string | no | A plain `*.svg` or `*.png` file name in the widget directory, rendered **untinted** in the picker. If absent - or declared but missing on disk - the picker shows a neutral fallback glyph instead of a blank tile. |
| `config` | object[] | no | Config-form fields (below). |

Unknown top-level keys are **ignored** (reserved for future manifest versions).

### `config` fields

Each entry describes one field of the widget's config form, rendered by the
same panel shipped widgets use. Every declared field **must** be honoured by
the widget (read it via the `cfg` pattern in the [authoring guide](authoring.md)
- no decorative toggles).

| Key | Required | Rules |
|---|---|---|
| `key` | yes* | Identifier (`^[A-Za-z][A-Za-z0-9_]*$`); the settings key your widget reads. `title`, `accent` and `cardBackdrop` are reserved (the universal General/Appearance sections own them). *Not used by `info` fields. |
| `label` | yes* | Non-empty display label. *Not used by `info` fields. |
| `type` | yes | One of `text`, `textarea`, `number`, `slider`, `toggle`, `segmented`, `date`, `hour`, `info`. (`action`, `tasks` and `accent` are host-owned and not available to manifests.) |
| `text` | `info` only | The informational text to display. |
| `dflt`, `help`, `placeholder`, `min`, `max`, `step`, `options` | no | Passed through to the form renderer with the same meaning as shipped schemas (`ui/qml/WidgetConfigSchema.qml`). |

The form the user sees is: your **Settings** section (if any) → the standard
**General** (custom title) section → **About** (your `description`) → the
universal **Widget appearance** section (accent + card backdrop) - identical
composition to a shipped widget.

### The entry QML file

The entry file is a normal widget per the [authoring guide](authoring.md): the
host injects `metrics`, `expanded`, `active`, `store`, `instanceId`,
`sizeClass`, `tick`, `netHub`, `timeZones` onto any property you declare, and
`theme` resolves from context. Root it in `WidgetChrome` for the shared glass
card - qrc-bundled framework components are importable from user QML with:

```qml
import "qrc:/qml"    // WidgetChrome, AppIcon, PillButton, MetricGauge, …
```

If the widget fetches anything, declare `property var netHub: null` and route
every request through `netHub.request({...})` - see
[Security posture](#security-posture-tier-0--the-honest-version) for what that
does and does not guarantee.

---

## Loader behavior and failure modes

The hub scans `$XDG_DATA_HOME/xeneon-edge-hub/widgets/*/` at startup (only when
`enableUserWidgets` is true), reads each `manifest.json`, validates it against
this spec, and registers valid entries in the widget catalog. From there they
are ordinary widgets: they appear in the add-widget picker (under their
`category`), load into tiles, expand, persist settings, and honour the size
rules.

**A broken widget is skipped, never fatal.** Every failure mode below skips
*that one directory*, records a reason, and continues:

| Condition | Result |
|---|---|
| Flag off (default) | Directory not scanned at all. |
| Load directory absent | Nothing to do; no error. |
| `manifest.json` missing / unreadable / over 256 KiB | Skipped: `missing manifest.json` (or unreadable/oversized). |
| Malformed JSON | Skipped: `manifest.json is not valid JSON (…)`. |
| `manifestVersion` ≠ 1 | Skipped: unsupported version. |
| `type` not `user.*`-namespaced, or collides with a shipped type | Skipped - **shipped wins**, always. |
| Duplicate `type` across two directories | First (directory name order) wins; second skipped. |
| `entry` missing from the directory, or not a plain `.qml` name | Skipped. |
| Illegal `sizes` entry / empty `sizes` / `dflt` not in `sizes` | Skipped. |
| Invalid `config` field | Skipped (strict: a manifest that lies about its form is not half-loaded). |
| `icon` declared but file absent | **Loaded anyway** with the fallback glyph; a warning is logged. |
| Entry QML fails at runtime (syntax error, missing import) | The tile stays blank and the QML engine logs the error; the rest of the dashboard is unaffected. |
| Flag later turned off / widget deleted while tiles reference it | Tiles render the standard "This widget isn't available" fallback card; settings are retained. |

Every skip reason is visible in **Diagnostics → Config → "User widgets
(Tier-0)"** on the device, and is also emitted as a structured
`[user-widgets] skipped <dir> - <reason>` warning on stderr.

**Load order note:** user widgets register *before* the persisted layout loads,
so a stored tile's size is validated against the manifest's declared `sizes`
exactly like a shipped widget's. If a manifest disappears, its tiles' sizes are
coerced to the baseline on the next load - reinstating the widget restores the
type but not a coerced size.

The Manager does not currently render user widgets: its WYSIWYG clone shows the
standard fallback card for them. Manage their layout on the device.

---

## Security posture (Tier-0) - the honest version

User widgets are **arbitrary code**. This section states exactly what is and is
not guaranteed. Nothing here is a sandbox, and we do not pretend otherwise.

- **Shipped widgets are gated and attested.** Everything in this repository
  must route egress through the NetHub gate (`scripts/check_no_raw_xhr.sh`
  fails the build on a raw `XMLHttpRequest`), and the no-egress CI attestation
  runs the hub in its **default** configuration. User widgets are outside both:
  the lint only scans repository sources, and the attested default config has
  user widgets disabled.
- **A user widget can do anything the hub process can do.** It runs
  unsandboxed, in-process, with your privileges. It can read your files,
  construct a raw `XMLHttpRequest`, and bypass NetHub's offline switch, host
  allowlist and request counters entirely. QML cannot be meaningfully
  sandboxed, and a half-sandbox would be more dangerous than the truth. Treat
  installing a user widget exactly like installing any other program - the same
  trust level as a Rainmeter skin or a shell script you download: read it, or
  trust its author.
- **The loader defaults OFF.** `enableUserWidgets` defaults to `false`, so a
  stock install never scans the directory and never loads user QML, and the
  no-egress attestation over the default configuration stays meaningful.
  Enabling the flag is an explicit opt-in that changes the trust story of the
  install - that is the point of the flag.
- **Managed/enterprise config can force it off.** The flag is a plain config
  read; a managed configuration that pins `enableUserWidgets` to `false` wins,
  regardless of what is on disk.
- **A well-behaved user widget still gets the gate.** The hub injects `netHub`
  into user widgets exactly as it does shipped ones, so a widget that declares
  the property and routes through `netHub.request({...})` honours the global
  offline switch and appears in the egress counters. This is cooperation, not
  enforcement: a user widget that constructs its own XHR is invisible to the
  offline switch, the allowlist, the counters and the attestation. The gate
  proves what *shipped* code does; for user code it is an offer.

---

## Versioning

- `manifestVersion` is bumped only for **breaking** changes to this contract.
  A hub speaking version 1 skips (never guesses at) higher-version manifests.
- Additive evolution happens via new optional keys, which version-1 hubs
  ignore. Do not rely on unknown-key passthrough for widget behavior.
