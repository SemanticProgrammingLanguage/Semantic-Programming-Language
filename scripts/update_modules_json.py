#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import urlparse


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--url", required=True)
    args = ap.parse_args()

    path = Path(args.file)
    parsed = urlparse(args.url)
    if parsed.scheme != "https" or not parsed.netloc:
        fail("Registry URL must be an absolute HTTPS URL")

    try:
        registry = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        registry = []
    except Exception as exc:
        fail(f"Could not parse {path}: {exc}")

    if not isinstance(registry, list):
        fail(f"{path} must contain a JSON array")

    name_in = args.name.strip()
    url_in = args.url.strip()
    cleaned = []
    found = False

    for item in registry:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name", "")).strip()
        url = str(item.get("url", "")).strip()
        if not name or not url:
            continue
        if name.casefold() == name_in.casefold():
            cleaned.append({"name": name_in, "url": url_in})
            found = True
        else:
            cleaned.append({"name": name, "url": url})

    if not found:
        cleaned.append({"name": name_in, "url": url_in})

    cleaned.sort(key=lambda x: x["name"].casefold())
    path.write_text(json.dumps(cleaned, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Updated {path}: {name_in} -> {url_in}")


if __name__ == "__main__":
    main()
