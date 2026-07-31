---
apply: always
---

# Core Project Rules

This repository contains a native Linux application for secondary touchscreen
displays, primarily the Corsair Xeneon Edge.

Prioritize, in order:

1. Stability
2. Correctness
3. Touch usability
4. Multi-monitor reliability
5. Low resource consumption
6. Security
7. Maintainability
8. Extensibility
9. Visual quality

General requirements:

- Inspect relevant implementation, tests, and documentation before editing.
- Prefer the smallest coherent change that satisfies the requirement.
- Avoid unrelated refactoring.
- Do not invent APIs, commands, files, capabilities, or test results.
- Do not claim that code builds or tests pass unless they were executed.
- Do not add dependencies without explaining the need.
- Preserve public APIs and configuration formats unless explicitly changing them.
- Handle missing hardware, sensors, services, and integrations gracefully.
- Never block the UI thread with file, network, database, hardware, or process I/O.
- Avoid unnecessary polling, background processes, disk writes, and rendering.
- Follow XDG directory conventions.
- Never expose or commit credentials, tokens, private keys, or customer data.
- Ask before destructive Git, database, infrastructure, or system operations.
- Add or update focused tests for behavioral changes.
- Inspect the final diff before declaring completion.

Product constraints:

- The application must remain self-contained.
- Do not turn it into an externally launched browser kiosk.
- Do not introduce an always-running external web server without an approved ADR.
- Support portrait and landscape layouts.
- Support KDE and GNOME, with Wayland and X11 considered.
- Never silently fall back to the primary display.
- Do not hard-code connector names such as DP-1.
- Do not repeatedly modify compositor or window-manager rules.
- Do not steal focus, trap the pointer, or interfere with the primary desktop.