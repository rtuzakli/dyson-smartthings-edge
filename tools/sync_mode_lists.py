#!/usr/bin/env python3
"""Copy the mode lists from src/dyson.lua into presentation/device_config.json.

The routine editor offers a `mode` value only if the presentation lists it as an alternative, so
each mode row in the device configuration carries a patch with the driver's list (see README,
"Modes in routines"). Run this after changing a mode list in src/dyson.lua, then create a new
device configuration. `--check` only reports whether the file is up to date (exit 1 if not).

Usage: python3 tools/sync_mode_lists.py [--check]
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DYSON = ROOT / "src" / "dyson.lua"
CONFIG = ROOT / "presentation" / "device_config.json"

# Device component -> list in src/dyson.lua.
COMPONENT_LISTS = {
    "humidifier": "HUMIDITY_MODES",
    "oscillation": "OSCILLATION_MODES",
    "airflow": "AIRFLOW_MODES",
    "sleepTimer": "SLEEP_TIMER_MODES",
    "waterHardness": "WATER_HARDNESS_MODES",
}

STRING = r'"((?:[^"\\]|\\.)*)"'


def lua_lists(source):
    """Returns {name: [labels]} for the M.<NAME>_MODES lists, resolving M.<CONST> string names."""
    consts = {}
    # M.OFF = "Off"  and  M.FRONT, M.BACK = "Front", "Back"
    for line in source.splitlines():
        m = re.match(r'^((?:M\.\w+\s*,\s*)*M\.\w+)\s*=\s*("[^{}]*")\s*(--.*)?$', line)
        if not m:
            continue
        keys = [k.strip()[2:] for k in m.group(1).split(",")]
        vals = re.findall(STRING, m.group(2))
        if len(keys) == len(vals):
            consts.update(zip(keys, vals))
    lists = {}
    for name in COMPONENT_LISTS.values():
        m = re.search(r'^M\.' + name + r'\s*=\s*\{([^}]*)\}', source, re.M)
        if not m:
            raise SystemExit(f"{DYSON}: M.{name} not found")
        items = []
        for item in (i.strip() for i in m.group(1).split(",")):
            if not item:
                continue
            s = re.fullmatch(STRING, item)
            if s:
                items.append(s.group(1))
            elif item.startswith("M.") and item[2:] in consts:
                items.append(consts[item[2:]])
            else:
                raise SystemExit(f"{DYSON}: cannot read {item!r} in M.{name}")
        lists[name] = items
    return lists


def synced(config, lists):
    """Returns (new config, number of mode rows)."""
    rows = 0
    for kind in ("conditions", "actions"):
        for entry in config["automation"][kind]:
            name = COMPONENT_LISTS.get(entry["component"])
            if entry["capability"] != "mode" or not name:
                continue
            alternatives = [{"key": m, "value": m, "type": "active"} for m in lists[name]]
            entry["patch"] = [{"op": "replace", "path": "/0/list/alternatives", "value": alternatives}]
            rows += 1
    return config, rows


def main():
    check = "--check" in sys.argv[1:]
    raw = CONFIG.read_text(encoding="utf-8")
    config, rows = synced(json.loads(raw), lua_lists(DYSON.read_text(encoding="utf-8")))
    text = json.dumps(config, indent=2, ensure_ascii=False) + ("\n" if raw.endswith("\n") else "")
    if text == raw:
        print(f"{CONFIG.relative_to(ROOT)}: {rows} mode rows up to date")
        return 0
    if check:
        print(f"{CONFIG.relative_to(ROOT)}: mode lists out of date, run tools/sync_mode_lists.py")
        return 1
    CONFIG.write_text(text, encoding="utf-8")
    print(f"{CONFIG.relative_to(ROOT)}: {rows} mode rows updated; create a new device configuration")
    return 0


if __name__ == "__main__":
    sys.exit(main())
