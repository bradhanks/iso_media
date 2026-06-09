#!/usr/bin/env python3
"""PreToolUse Bash guard for the lifecycle-security-auditor subagent.

Claude Code passes the hook payload as JSON on stdin. This guard inspects the
Bash command, splits it on shell operators so chaining can't smuggle past a
prefix check, and:
  - exit 0  -> allow the call to proceed through normal permission handling
  - exit 2  -> block the call; the stderr text is shown to the model

It is a guard, not an OS sandbox: it narrows what the agent will run, but real
isolation still comes from running Claude Code in a sandboxed environment.
"""
import json
import re
import sys

# Commands the auditor is allowed to run. Each pattern is matched (from the
# start) against a single shell segment that has already been split off.
ALLOW = [
    r"mix\s+format(\s+--check-formatted)?\s*$",
    r"mix\s+credo(\s+--strict)?\s*$",
    r"mix\s+compile(\s+--warnings-as-errors)?\s*$",
    r"mix\s+test(\s+\S+)*\s*$",
    r"rg\s+\S.*",
    r"grep\s+\S.*",
    r"(cat|ls|find|head|tail|wc|stat)\s+\S.*",
    r"git\s+(status|diff|log|show)(\s+\S+)*\s*$",
]

# Hard denies — blocked even if a segment also happens to match an allow rule.
# Checked with re.search over the whole segment, so they also catch attempts
# hidden inside $(...) / backticks.
DENY = [
    r"\brm\b", r"\bmv\b", r"\bdd\b", r"\bchmod\b", r"\bchown\b",
    r"\bsudo\b", r"\bcurl\b", r"\bwget\b", r"\bnc\b",
    r"\bgit\s+(push|reset|checkout|clean|rebase|merge)\b",
    r"mix\s+ecto\.(drop|reset|rollback)\b",
    r"mix\s+deps\.",
    r">", r">>",  # output redirection
]

# Top-level shell operators we split on. (Operators inside $(...) are left
# intact in the segment and caught by the DENY search above.)
SPLIT = re.compile(r"&&|\|\||[;|\n]")


def block(reason: str) -> None:
    print(f"audit-bash-guard: {reason}", file=sys.stderr)
    sys.exit(2)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        block("could not parse the hook payload")

    if payload.get("tool_name") != "Bash":
        sys.exit(0)  # not a Bash call; nothing to guard

    command = (payload.get("tool_input") or {}).get("command", "") or ""
    segments = [s.strip() for s in SPLIT.split(command) if s.strip()]
    if not segments:
        sys.exit(0)

    for seg in segments:
        bare = re.sub(r"^(?:\w+=\S+\s+)+", "", seg).strip()  # drop FOO=bar prefixes

        if any(re.search(p, bare) for p in DENY):
            block(f"command segment blocked by a deny rule: {seg!r}")

        if not any(re.match(p, bare) for p in ALLOW):
            block(
                "command segment is not on the auditor allowlist: "
                f"{seg!r}\nAllowed: mix format|credo|compile|test, rg/grep, "
                "and read-only file/git inspection (cat, ls, find, head, tail, "
                "wc, stat, git status|diff|log|show)."
            )

    sys.exit(0)


if __name__ == "__main__":
    main()
