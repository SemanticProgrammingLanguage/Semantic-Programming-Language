#!/usr/bin/env python3
import json, os, re, sys, tempfile, urllib.request, zipfile
from pathlib import Path
from urllib.parse import urlparse

ISSUE_BODY = os.environ.get("ISSUE_BODY", "")
REGISTRY_PATH = Path(os.environ.get("REGISTRY_PATH", "modules.json"))

def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)

def read_issue_field(label):
    m = re.search(
        rf"###\s+{re.escape(label)}\s*\n+\s*(.+?)(?=\n###\s|\Z)",
        ISSUE_BODY,
        re.I | re.S,
    )
    if not m:
        fail(f"Could not read '{label}' from the GitHub Issue Form.")
    return re.sub(r"<!--.*?-->", "", m.group(1), flags=re.S).strip()

name = read_issue_field("Module name")
url = read_issue_field("Module ZIP URL")

if not (1 <= len(name) <= 128):
    fail("Module name must contain between 1 and 128 characters.")

u = urlparse(url)
if u.scheme != "https" or not u.netloc:
    fail("The module archive must use a public HTTPS URL.")

request = urllib.request.Request(
    url,
    headers={
        "User-Agent": "Semantic-Module-Registry/1.0",
        "Accept": "application/zip,application/octet-stream,*/*;q=0.8",
    },
)

try:
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
except Exception as exc:
    fail(f"Could not download the module archive: {exc}")

tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".zip")
tmp.write(data)
tmp.close()

try:
    try:
        zf = zipfile.ZipFile(tmp.name)
    except Exception:
        fail("The URL does not point to a readable ZIP archive.")

    with zf:
        files = [i.filename for i in zf.infolist() if not i.is_dir()]

        for filename in files:
            p = Path(filename)
            if p.is_absolute() or ".." in p.parts:
                fail("The ZIP contains an unsafe path.")

        smods = [f for f in files if f.lower().endswith(".smod")]
        if len(smods) != 1:
            fail("The ZIP must contain exactly one .smod manifest.")

        readmes = [f for f in files if re.search(r"(^|/)readme\.(md|txt)$", f, re.I)]
        licenses = [f for f in files if re.search(r"(^|/)license\.(md|txt)$", f, re.I)]
        icons = [f for f in files if re.search(r"(^|/)[^/]+\.ico$", f, re.I)]

        # Best-effort manifest name check. It accepts common JSON/TOML/YAML-like forms.
        manifest_text = zf.read(smods[0]).decode("utf-8", "replace")
        declared_name = None
        patterns = [
            r'(?im)^\s*"name"\s*:\s*"([^"]+)"',
            r"(?im)^\s*name\s*=\s*[\"']([^\"']+)[\"']",
            r"(?im)^\s*name\s*:\s*[\"']?([^\"'\r\n,#]+)",
            r'(?im)^\s*"module"\s*:\s*"([^"]+)"',
        ]
        for pattern in patterns:
            mm = re.search(pattern, manifest_text)
            if mm:
                declared_name = mm.group(1).strip()
                break

        if declared_name and declared_name.casefold() != name.casefold():
            fail(
                f"The submitted name '{name}' does not match the .smod name "
                f"'{declared_name}'."
            )

        print(f"✓ .smod: {smods[0]}")
        print("✓ README:", readmes[0] if readmes else "optional file not present")
        print("✓ License:", licenses[0] if licenses else "optional file not present")
        print("✓ Icon:", icons[0] if icons else "optional file not present")
finally:
    try:
        os.unlink(tmp.name)
    except OSError:
        pass

try:
    registry = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
except FileNotFoundError:
    registry = []
except Exception as exc:
    fail(f"Could not read modules.json: {exc}")

if not isinstance(registry, list):
    fail("modules.json must be a JSON array.")

existing = next(
    (item for item in registry
     if isinstance(item, dict)
     and str(item.get("name", "")).casefold() == name.casefold()),
    None,
)

def archive_version(value):
    filename = Path(urlparse(value).path).name
    m = re.match(r"^(.*?)(?:[-_.]?v(\d+))?\.zip$", filename, re.I)
    if not m:
        return filename.casefold(), 1
    base = (m.group(1) or "").rstrip("-_.").casefold()
    return base, int(m.group(2) or 1)

if existing:
    old_url = str(existing.get("url", ""))
    old = urlparse(old_url)
    new = urlparse(url)
    old_base, old_version = archive_version(old_url)
    new_base, new_version = archive_version(url)

    if old.netloc.casefold() != new.netloc.casefold():
        fail("Updates must remain on the same host as the existing module.")

    if str(Path(old.path).parent).casefold() != str(Path(new.path).parent).casefold():
        fail("Updates must remain in the same URL directory as the existing module.")

    if old_base != new_base:
        fail("Updates must keep the same ZIP base name.")

    if new_version <= old_version:
        fail(f"The update must use a version higher than v{old_version}.")

    existing["url"] = url
    action = "updated"
else:
    if any(
        isinstance(item, dict)
        and str(item.get("url", "")).casefold() == url.casefold()
        for item in registry
    ):
        fail("This ZIP URL is already registered.")

    registry.append({"name": name, "url": url})
    action = "added"

registry.sort(key=lambda item: str(item.get("name", "")).casefold())
REGISTRY_PATH.write_text(
    json.dumps(registry, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)

print(f"✓ Module {action}: {name}")
