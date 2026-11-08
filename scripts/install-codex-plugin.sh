#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 || ! "$1" =~ ^[a-z0-9]{10,}$ ]]; then
  echo "Usage: $0 <memohub-project-ref> [home-mac|work-mac] [memohub-private-ref]" >&2
  echo "Get the shared memohub project ref from Supabase → Project Settings." >&2
  exit 2
fi

device="${2:-${MEMOHUB_DEVICE:-}}"
private_ref="${3:-${MEMOHUB_PRIVATE_REF:-}}"
if [[ -z "$device" ]]; then
  read -r -p "Which device is this? [home-mac/work-mac]: " device
fi
if [[ "$device" != "home-mac" && "$device" != "work-mac" ]]; then
  echo "Device must be home-mac or work-mac." >&2
  exit 2
fi
if [[ -n "$private_ref" && ! "$private_ref" =~ ^[a-z0-9]{10,}$ ]]; then
  echo "Private project ref must contain lowercase letters and digits." >&2
  exit 2
fi
if [[ -n "$private_ref" && "$device" != "home-mac" ]]; then
  echo "A private Memohub connection is allowed only on home-mac." >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
marketplace_root="$HOME/.agents/plugins"
plugin_dir="$marketplace_root/memohub"
marketplace_path="$marketplace_root/marketplace.json"

mkdir -p "$plugin_dir"
cp -R "$repo_root/codex-plugin/." "$plugin_dir/"

python3 - "$plugin_dir/mcp.json" "$1" "$device" "$private_ref" "$marketplace_path" <<'PY'
import json
import pathlib
import sys

mcp_path = pathlib.Path(sys.argv[1])
project_ref = sys.argv[2]
device = sys.argv[3]
private_ref = sys.argv[4]
marketplace_path = pathlib.Path(sys.argv[5])

mcp = json.loads(mcp_path.read_text())
mcp["mcpServers"]["memohub"]["url"] = (
    "https://mcp.supabase.com/mcp?project_ref=" + project_ref + "&features=database"
)
if private_ref:
    private = dict(mcp["mcpServers"]["memohub"])
    private["url"] = (
        "https://mcp.supabase.com/mcp?project_ref=" + private_ref + "&features=database"
    )
    mcp["mcpServers"]["memohub-private"] = private
mcp_path.write_text(json.dumps(mcp, ensure_ascii=False, indent=2) + "\n")
(mcp_path.parent / "DEVICE").write_text(device + "\n")

if marketplace_path.exists():
    marketplace = json.loads(marketplace_path.read_text())
else:
    marketplace = {
        "name": "personal",
        "interface": {"displayName": "Personal plugins"},
        "plugins": [],
    }

plugins = marketplace.setdefault("plugins", [])
entry = next((item for item in plugins if item.get("name") == "memohub"), None)
if entry is None:
    entry = {"name": "memohub"}
    plugins.append(entry)
entry.update(
    {
        "source": {"source": "local", "path": "./.agents/plugins/memohub"},
        "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
        "category": "Productivity",
    }
)
marketplace_path.write_text(json.dumps(marketplace, ensure_ascii=False, indent=2) + "\n")
PY

echo "Memohub added to the personal Codex marketplace. Restart Codex, install it from the Plugins Directory, and complete OAuth for each configured database."
