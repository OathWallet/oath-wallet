"""Check public security examples against their exact released Git revision.
Usage: python3 scripts/verify-source-excerpts.py /path/to/public/oath-wallet
Reads Git objects only; never reads ignored local credentials.
"""
import json
from pathlib import Path
import subprocess
import sys
site=Path(__file__).resolve().parents[1]
evidence=json.loads((site/'content/release-evidence.json').read_text())
repo=sys.argv[1]
for entry in evidence['files']:
    source=subprocess.run(['git','show',f"{evidence['source_commit']}:{entry['path']}"],cwd=repo,check=True,capture_output=True,text=True).stdout
    excerpt=''.join(source.splitlines(keepends=True)[entry['start']-1:entry['end']])
    if excerpt != entry['code']:
        raise SystemExit('Source excerpt mismatch: '+entry['path'])
print(f"Verified {len(evidence['files'])} exact source excerpts at {evidence['source_commit']}.")

# The canonical checkout in CI fetches the public tags. A contributor can have
# other local tags, so require this identity check explicitly during publication.
if "--verify-release-tag" in sys.argv[2:]:
    version = evidence["version"]
    record = json.loads((site.parent / "releases" / f"{version}-distribution.json").read_text())
    ref = "refs/tags/" + record["source_tag"] + "^{commit}"
    tag_commit = subprocess.check_output(["git", "rev-parse", "--verify", ref], cwd=repo, text=True).strip()
    if tag_commit != record["source_commit"] or tag_commit != evidence["source_commit"]:
        raise SystemExit("Published release tag and website source evidence disagree")
    print(f"Verified public source tag {record['source_tag']} at {tag_commit}.")
