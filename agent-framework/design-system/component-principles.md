# Component Principles (Extracted Patterns)

Source: CompanyWebsite (read-only), 2026-07-18. These are *pattern descriptions with evidence*, not CSS to copy verbatim — new products implement them with semantic tokens, not copied class strings.

## Buttons

Four extracted variants (portal `.btn-*`, `portal.css:186-228`): **primary** (brand navy → primary-dark hover), **secondary** (blue → `#2563eb` hover), **outline** (white, `#374151` text, `#d1d5db` border, `#f9fafb` hover), **danger** (`#dc2626` → `#b91c1c`). Shape: `0.5rem` radius, `0.5rem 1rem` padding, weight 500, 0.2s transitions, 44px min height on touch. On-brand contexts invert (white button, navy text — `custom.css:77-85`). Rule: destructive actions always use the danger variant plus a confirmation step (see Destructive actions).

**ACCESSIBILITY WARNING — secondary button:** the extracted resting `secondary` variant (white text on `#3b82f6`) measures 3.68:1 at 0.875rem/500 — this FAILS WCAG AA 4.5:1 for non-large text. Extracted as-is (do not silently "fix" the token value); this ratio MUST NOT be replicated for new text at this size/weight. The extracted hover color `#2563eb` measures 5.17:1 (white text on `#2563eb`) and is the conforming default for any new secondary-button text — prefer it over the resting `#3b82f6` on new text-bearing surfaces. See `tokens/light.json` `component.button-secondary` note.

## Cards

White surface, 1px `#e5e7eb`/`#f3f4f6` border, `rounded-xl`, `shadow-sm` at rest, hover = soft shadow + ≤2px lift (`www/index.php:47`, `custom.css:57-62`). Variants: stat card (`portal.css:231-245` — 1.5rem padding, 1.875rem/700 value, muted label), accent-stripe list card (`border-l-4` in brand hues, `www/index.php:126-142`), icon tile (`w-12 h-12` rounded-lg/full tinted background).

## Navigation

Marketing: sticky white top bar, active = `text-secondary` + `bg-blue-50`, hover dropdowns with shadow-lg (`www/partials/header.php:118-190`). App: fixed 16rem left sidebar, active item = solid brand navy + white text, off-canvas mobile with overlay and Escape-close (`portal/includes/header.php:126-143`, `portal/includes/footer.php:5-29`). Rule: exactly one primary navigation paradigm per product; active state must be visible without color perception (weight/positioning cue too).

## Forms

Inputs: white, 1px `#d1d5db` border, `0.5rem` radius, `0.5rem 0.75rem` padding; focus = secondary border + 3px soft ring (`portal.css:65-77`); labels 0.875rem/500 (`portal.css:172-178`); inline error text 0.75rem `#dc2626` (`portal.css:179-183`); 16px font on mobile inputs (iOS zoom guard). Rules: every input has a visible label (no placeholder-as-label); errors are text + color, adjacent to the field; error recovery must preserve user input.

## Tables

Uppercase 0.75rem/600 gray headers on `#f9fafb`, 1px row dividers, row hover wash, cell padding `0.75rem 1rem` (`portal.css:19-39`); mobile: card-transform with `data-label` pseudo-content (`portal.css:327-355`).

## Badges & status

Pill (`rounded-full`, `px-2 py-1 text-xs`) with tinted bg + dark text of the same hue; extracted status mapping in `portal/includes/functions.php:227-236`. Rule: status must also be readable as text — color is reinforcement, not the message.

## Alerts & feedback

Four variants (success/warning/info/error) as tinted bg + matching border + dark text (`portal.css:248-274`); flash banners at content top (`portal/includes/header.php:329-339`). Progress bar (pill track + brand fill, `portal.css:277-288`) and 0.8s spinner (`portal.css:291-301`).

## Empty / loading / error states (binding pattern)

Extraction found spinners and alerts but no designed empty states — treat as a gap every new product must fill:
- **Empty:** explain what would appear here + the primary action to create it; never a blank region.
- **Loading:** spinner or skeleton after ~300ms delay; preserve layout (no jumps); announce via `aria-busy`/live region.
- **Error:** what failed, in plain language + retry action + preserved input; use the error alert pattern; log correlation id where applicable.

## Destructive actions (binding pattern)

Danger variant button + explicit confirmation that names the object ("Delete project X?"), typed confirmation for irreversible bulk deletes, no default-focused destructive button, undo where feasible. (Extraction: portal has danger buttons but no documented confirmation pattern — gap flagged.)

## Density & responsiveness

Comfortable default density (44px touch targets, 0.75–1rem cell padding); breakpoints 640/768/1024 with wide tiers 1920+ (container-wide) and 375px compact adjustments; wide screens grow the container, not the font-only. Print styles exist (`custom.css:218`, `portal.css:416`) — keep exports printable.

## Typography & legibility (binding)

Type rules live in `typography-and-legibility.md` in this directory: a declared font family must be shipped or the design must target the generic stack explicitly; checks confirm the family that *rendered*, not the one requested; text boxes are sized from measured font metrics, never `fontSize + constant`; containers never compress text below its measured line box; and each product states the user-text-scale range it supports and verifies its densest surfaces at the top of it. Every rule there carries the production measurement that produced it.

## Focus & keyboard (binding)

2px visible outline, 2px offset, on every interactive element (`custom.css:40-47`); never `outline: none` without an equal-or-better visible replacement; skip link on every page (`custom.css:19-32` — currently missing in portal); logical tab order; Escape closes overlays.
