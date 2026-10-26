"""Check local Markdown targets in the maintained entry points (no network required)."""
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

root = Path(__file__).resolve().parents[2]
errors = []
for name in sys.argv[1:]:
    source = root / name
    if not source.is_file():
        errors.append(f"Missing document: {name}")
        continue
    body = re.sub(r"```.*?```", "", source.read_text(), flags=re.S)
    for match in re.finditer(r"!?\[[^\]]*\]\(([^\s)]+)(?:\s+[^)]*)?\)", body):
        target = match.group(1).strip("<>")
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc or not parsed.path:
            continue
        destination = (source.parent / unquote(parsed.path)).resolve()
        if not destination.is_relative_to(root) or not destination.exists():
            errors.append(f"{name}: missing local target {target}")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Checked local links in {len(sys.argv) - 1} documents.")
