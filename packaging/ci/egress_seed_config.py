#!/usr/bin/env python3
"""Seed an isolated hub config.toml for the no-egress attestation.

Usage: egress_seed_config.py <config_dir> <mode> [url]

Modes:
  default   Write NOTHING. A pristine config dir is what a new install has, and
            the claim under test is about the DEFAULT hub, so the run must not
            be handed a config the hub itself would not have written.
  seeded    first_run_complete + no ui_state -> the hub seeds its default
            starter layout ("productivity"). This is the post-wizard default
            dashboard, which `default` (still on the wizard) never reaches.
  weather   One Weather tile with an explicit Berlin location. Weather fetches
            about 350 ms after load, so this needs no interaction.
  url       One HTTP/JSON tile pointed at <url>. This is the negative control:
            an arbitrary host is exactly what "the app phones home" looks like.

Schema rules the Rust core is strict about (learned in tests/runtime/, see that
README): the config is NESTED - [display]/[theme]/[startup]/[widgets] are
required tables, and a flat layout deserialize-fails, gets salvaged into the
default layout, and silently discards the seed. `ui_state` must be a
single-quoted TOML *literal* string: the embedded JSON has double quotes, and a
basic "..." string with \\"-escapes is rejected.
"""
import json
import os
import sys


def ui_state_for(mode: str, url: str) -> str:
    if mode == "weather":
        tiles = [{"id": "weather-1", "type": "weather", "w": 1, "h": 2}]
        settings = {
            "weather-1": {
                "lat": 52.52,
                "lon": 13.405,
                "place": "Berlin",
            }
        }
    elif mode == "url":
        tiles = [{"id": "httpjson-1", "type": "httpjson", "w": 1, "h": 2}]
        settings = {"httpjson-1": {"url": url, "jsonPath": "value", "pollSec": 2, "mode": "value"}}
    else:
        raise SystemExit("ui_state_for: unexpected mode %r" % mode)
    return json.dumps({
        "version": 1,
        "appearance": {"mode": "dark", "accent": "#58A6FF"},
        "settings": settings,
        "pages": [{"name": "Net", "tiles": tiles}],
    })


def build_config(ui_state: str | None) -> str:
    lines = ["schema_version = 1", "first_run_complete = true"]
    if ui_state is not None:
        assert "'" not in ui_state, "JSON unexpectedly contains a single quote"
        lines.append("ui_state = '%s'" % ui_state)
    lines += [
        "",
        "[display]",
        'fallback_behavior = "hide"',
        'starter_layout = "productivity"',
        "",
        "[theme]",
        'mode = "dark"',
        'accent_color = "#58A6FF"',
        "reduced_motion = false",
        "",
        "[startup]",
        "autostart = false",
        "reconnect_on_hotplug = true",
        "notify_on_disconnect = false",
        "",
        "[widgets]",
        "version = 1",
        "instances = []",
        "",
    ]
    return "\n".join(lines)


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    config_dir, mode = sys.argv[1], sys.argv[2]
    url = sys.argv[3] if len(sys.argv) > 3 else ""
    os.makedirs(config_dir, exist_ok=True)

    if mode == "default":
        print("seeded: nothing (pristine config dir - the hub writes its own defaults)")
        return
    ui_state = None if mode == "seeded" else ui_state_for(mode, url)
    with open(os.path.join(config_dir, "config.toml"), "w") as f:
        f.write(build_config(ui_state))
    print("seeded: mode=%s%s" % (mode, (" url=" + url) if url else ""))


if __name__ == "__main__":
    main()
