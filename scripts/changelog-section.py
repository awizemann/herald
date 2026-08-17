#!/usr/bin/env python3
"""Extract one version's section from CHANGELOG.md.

usage: changelog-section.py <version> [--html]
Prints the markdown body of `## [<version>]` (without the heading), or a minimal HTML
rendering with --html (for Sparkle's embedded release notes). Exit 1 if the section is
missing or empty — release.sh treats that as "no notes written, refuse to release".
"""
import html
import re
import sys
from pathlib import Path

def section(version: str) -> str:
    text = Path(__file__).resolve().parents[1].joinpath("CHANGELOG.md").read_text()
    m = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.M | re.S)
    body = (m.group(1) if m else "").strip()
    # Drop the link-reference footer if the section is the last one.
    body = re.sub(r"^\[[^\]]+\]: \S+$", "", body, flags=re.M).strip()
    return body

def to_html(md: str) -> str:
    out, in_list, para = [], False, []
    def flush_para():
        nonlocal para
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para = []
    def inline(s: str) -> str:
        s = html.escape(s)
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', s)
        return s
    for raw in md.splitlines():
        line = raw.rstrip()
        if not line.strip():
            flush_para()
            if in_list: out.append("</ul>"); in_list = False
            continue
        if line.startswith("### "):
            flush_para()
            if in_list: out.append("</ul>"); in_list = False
            out.append(f"<h3>{inline(line[4:])}</h3>")
        elif re.match(r"^\s*-\s+", line):
            flush_para()
            if not in_list: out.append("<ul>"); in_list = True
            out.append("<li>" + inline(re.sub(r"^\s*-\s+", "", line)) + "</li>")
        elif in_list and line.startswith("  "):
            out[-1] = out[-1][:-5] + " " + inline(line.strip()) + "</li>"   # continuation line
        else:
            para.append(line.strip())
    flush_para()
    if in_list: out.append("</ul>")
    return "\n".join(out)

if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    version = args[0]
    body = section(version)
    if not body:
        sys.stderr.write(f"CHANGELOG.md has no '## [{version}]' section (or it is empty)\n")
        sys.exit(1)
    print(to_html(body) if "--html" in args else body)
