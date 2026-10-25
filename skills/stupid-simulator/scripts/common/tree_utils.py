#!/usr/bin/env python3
"""
Accessibility tree access through the stupidsim CLI.

`stupidsim ui-tree --json` reads the tree of the app in front through CoreSimulator, on Xcode 27
and iOS 26/27 runtimes, without IDB. Its elements are converted here to the shape the audit,
capture and recorder scripts were written against:

    {"type": "Button", "AXLabel": "Login", "AXValue": None, "AXUniqueId": "login",
     "frame": {"x": 16, "y": 120, "width": 361, "height": 44}, "children": [...]}

Frames are in points from the top-left of the screen, as `ui-tree` reports them.

Used by:
- accessibility_audit.py - WCAG compliance checking
- test_recorder.py - Test documentation
- app_state_capture.py - State snapshots
"""

import json
import os
import shutil
import subprocess
import sys

BUNDLED_CLI = "/Applications/stupid simulator.app/Contents/MacOS/stupidsim"


def stupidsim_path() -> str:
    """
    Locate the stupidsim CLI: $STUPIDSIM, then PATH, then the installed app bundle.

    Exits with an install hint when none is found, rather than falling back to another tool.
    """
    candidates = [os.environ.get("STUPIDSIM"), shutil.which("stupidsim"), BUNDLED_CLI]
    for candidate in candidates:
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    print(
        "Error: stupidsim not found. Install stupid simulator from "
        "https://github.com/stephancill/stupid-simulator/releases and choose "
        "stupid simulator > Install Command Line Tool, or set STUPIDSIM.",
        file=sys.stderr,
    )
    sys.exit(1)


def _convert(element: dict) -> dict:
    role = element.get("role") or ""
    origin, size = element.get("frame") or [[0, 0], [0, 0]]
    return {
        "type": role[2:] if role.startswith("AX") else (role or element.get("roleDescription") or "Element"),
        "role": role,
        "role_description": element.get("roleDescription"),
        "AXLabel": element.get("label") or element.get("title"),
        "AXValue": element.get("value"),
        "AXUniqueId": element.get("identifier"),
        "frame": {"x": origin[0], "y": origin[1], "width": size[0], "height": size[1]},
        "children": [_convert(child) for child in element.get("children", [])],
    }


def get_accessibility_tree(udid: str | None = None, nested: bool = True) -> dict:
    """
    Fetch the accessibility tree of the app in front.

    Args:
        udid: Device UDID, or None for the only booted simulator (`stupidsim` refuses when
            several are booted, rather than picking one).
        nested: Kept for compatibility with the IDB era. The tree is always nested; use
            flatten_tree() for a flat list.

    Returns:
        Root element (the application) in the shape described in the module docstring.

    Raises:
        SystemExit: If stupidsim fails or prints something that is not JSON.
    """
    cmd = [stupidsim_path(), "ui-tree", udid or "booted", "--json"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return _convert(json.loads(result.stdout))
    except subprocess.CalledProcessError as e:
        print(f"Error: Failed to get accessibility tree: {e.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError:
        print("Error: Invalid JSON from stupidsim ui-tree", file=sys.stderr)
        sys.exit(1)


def flatten_tree(node: dict, depth: int = 0, elements: list[dict] | None = None) -> list[dict]:
    """
    Flatten a nested tree into a list, each element carrying its "depth".
    """
    if elements is None:
        elements = []
    node_copy = node.copy()
    node_copy["depth"] = depth
    elements.append(node_copy)
    for child in node.get("children", []):
        flatten_tree(child, depth + 1, elements)
    return elements


def count_elements(node: dict) -> int:
    """Count every element in the tree, the root included."""
    return 1 + sum(count_elements(child) for child in node.get("children", []))
