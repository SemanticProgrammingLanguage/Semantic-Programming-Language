#!/usr/bin/env python3
import os
import re
import sys

body = os.environ.get("ISSUE_BODY", "")

def section(name):
    pattern = rf"(?ms)^###\s+{re.escape(name)}\s*\n(.*?)(?=^###\s+|\Z)"
    m = re.search(pattern, body)
    if not m:
        return ""
    value = m.group(1).strip()
    return value.splitlines()[0].strip() if value else ""

language = section("Source language")
package = section("Package")
module_name = section("Module name")
version = section("Release version")

if version == "(automatic)":
    version = ""

missing = [k for k,v in {
    "language": language,
    "package": package,
    "module_name": module_name,
}.items() if not v]

if missing:
    print("Missing issue fields: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)

out = os.environ["GITHUB_OUTPUT"]
with open(out, "a", encoding="utf-8") as f:
    f.write(f"language={language}\n")
    f.write(f"package={package}\n")
    f.write(f"module_name={module_name}\n")
    f.write(f"release_version={version}\n")
