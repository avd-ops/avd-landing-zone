"""Decide whether a pull request is low-risk enough to merge itself on green (decision 0014).

Stdlib-only, so a repo without the KB scripts can copy this one file:

  python3 scripts/kb/auto_merge.py --files changed.txt
      Reads the pull request from $GITHUB_EVENT_PATH and the changed paths (one per line, renames
      listed under both names) from changed.txt, and writes `eligible=true|false` and `reason=...`
      to $GITHUB_OUTPUT (or stdout). The kb-auto-merge workflow then turns GitHub's auto-merge on
      or off. It never merges anything itself, and anything it can't read makes the PR ineligible.

A PR is eligible only when all of these hold:
  - auto_merge = "on" in the settings, and KB_PAUSED isn't set
  - the repo owner's account opened it, from a branch of this repo, into the default branch, and
    it isn't a draft
  - it doesn't carry the no-auto-merge label
  - every changed path matches auto_merge_paths and none matches the fixed HARD_DENY list, which
    settings can't widen: decisions, directives, family and schema files, workflows, scripts,
    agent settings and instructions at any depth, guardrails, the family spec, and anything that
    looks like code, infra, config or a web page

Settings come from docs/knowledge/kb.toml in a repo with a KB, or .claude/kb-capture.toml in one
without (the same files as decision 0011's kb-capture settings):

  auto_merge = "on"                                  # default "off": each repo opts in
  auto_merge_paths = ["docs/knowledge/**", "llms.txt"]   # the low-risk set; this is the default
  auto_merge_deny = []                               # more paths this repo keeps for the owner
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KB_PATH = "docs/knowledge/"
HOLD_LABEL = "no-auto-merge"
DEFAULT_PATHS = ["docs/knowledge/**", "llms.txt"]
# The pulls/{n}/files API lists at most this many files; a bigger PR can't be fully read.
MAX_FILES = 3000
# Never low-risk, whatever auto_merge_paths says: these change rules, automation, agent instructions
# or running code. Matched against the lower-cased path, anywhere in the tree.
HARD_DENY = [
    "docs/knowledge/decisions/*", "docs/knowledge/directives.yaml", "docs/knowledge/family.yaml",
    "docs/knowledge/kb.toml", "docs/knowledge/schema/*", "docs/knowledge/curation.md",
    "docs/guardrails.md", "docs/2ndbrain/*", "template/*", "scripts/*", "skills/*", "license", "notice",
    ".github/*", "*/.github/*", ".claude/*", "*/.claude/*", "agents.md", "*/agents.md",
    "claude.md", "*/claude.md", "*skill.md", "codeowners", "*/codeowners", "*.cursorrules", "*.mdc",
    "*.py", "*.js", "*.mjs", "*.cjs", "*.ts", "*.tsx", "*.jsx", "*.sh", "*.ps1", "*.psm1", "*.psd1",
    "*.ps1xml", "*.bat", "*.cmd", "*.cs", "*.csproj", "*.go", "*.rs", "*.java", "*.rb", "*.php",
    "*.sql", "*.bicep", "*.bicepparam", "*.tf", "*.tfvars", "*.hcl", "*.json", "*.toml", "*.cfg",
    "*.ini", "*.env", "*.html", "*.htm", "*.svg", "dockerfile", "*/dockerfile", "makefile",
    "*/makefile",
]


def load_config(root: Path = ROOT) -> dict:
    kb_toml = root / KB_PATH / "kb.toml"
    path = kb_toml if kb_toml.exists() else root / ".claude" / "kb-capture.toml"
    cfg = {}
    if path.exists():
        with path.open("rb") as f:
            cfg = tomllib.load(f)
    return {
        "on": str(cfg.get("auto_merge", "off")).strip().lower() == "on",
        "paths": list(cfg.get("auto_merge_paths", DEFAULT_PATHS)),
        "deny": list(cfg.get("auto_merge_deny", [])),
    }


def matches(path: str, patterns: list[str]) -> bool:
    """fnmatch, where `*` also crosses `/`, so `docs/**` and `docs/*` both mean everything below."""
    return any(fnmatch.fnmatchcase(path, p) for p in patterns)


def verdict(pr: dict, files: list[str], owner: str, cfg: dict, env: dict | None = None) -> tuple[bool, str]:
    """(eligible, reason) for a pull request."""
    env = os.environ if env is None else env
    if not cfg["on"]:
        return False, "auto_merge is off for this repo"
    if env.get("KB_PAUSED", "").strip().lower() in ("true", "1", "yes"):
        return False, "KB_PAUSED is set on this repo"
    author = (pr.get("user") or {}).get("login", "")
    if not owner or author.lower() != owner.lower():
        return False, f"opened by {author or 'unknown'}, not the repo owner"
    head_repo = ((pr.get("head") or {}).get("repo") or {}).get("full_name", "")
    base_repo = ((pr.get("base") or {}).get("repo") or {}).get("full_name", "")
    if not head_repo or head_repo != base_repo:
        return False, "opened from a fork"
    base = pr.get("base") or {}
    default = ((base.get("repo") or {}).get("default_branch")) or ""
    if not default or base.get("ref") != default:
        return False, "not aimed at the default branch"
    if pr.get("draft"):
        return False, "draft"
    if HOLD_LABEL in [lb.get("name") for lb in pr.get("labels", [])]:
        return False, f"labelled {HOLD_LABEL}"
    changed = int(pr.get("changed_files") or 0)
    # Renames are listed under both names, so the count of paths alone can't show a truncated list.
    if changed > MAX_FILES:
        return False, f"more than {MAX_FILES} changed files, past what the API lists"
    if not files or len(set(files)) < changed:
        return False, "couldn't read the full list of changed files"
    for f in files:
        if matches(f.lower(), HARD_DENY) or matches(f, cfg.get("deny", [])):
            return False, f"{f} is never low-risk"
        if not matches(f, cfg["paths"]):
            return False, f"{f} is outside the low-risk paths"
    return True, f"all {len(set(files))} changed file(s) are in the low-risk paths"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--files", required=True, help="changed paths, one per line")
    args = ap.parse_args()
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        pr = event.get("pull_request") or {}
        owner = os.environ.get("AUTO_MERGE_OWNER") or os.environ.get("HANDOFF_OWNER") \
            or (event.get("repository") or {}).get("owner", {}).get("login", "")
        files = [ln.strip() for ln in Path(args.files).read_text().splitlines() if ln.strip()]
        ok, reason = verdict(pr, files, owner, load_config())
    except Exception as exc:  # fail closed: anything unreadable means a person merges it
        ok, reason = False, f"check failed: {exc}"
    reason = " ".join(reason.split())  # one line, so it can't forge another output
    lines = f"eligible={'true' if ok else 'false'}\nreason={reason}\n"
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(lines)
    print(("Auto-merge: " if ok else "No auto-merge: ") + reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
