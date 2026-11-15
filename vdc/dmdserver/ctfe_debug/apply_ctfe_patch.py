"""Applies the CTFE debugger patches described by the .spec files to ctfedebug.d.

A spec file contains blocks of the form

    <<<OLD
    <code as it currently is in the file>
    <<<NEW
    <replacement code>
    <<<END

The indentation of the OLD block is ignored when matching (leading whitespace of
every line is flexible), so the spec can be written with spaces.  The NEW block
is indented relative to the text it replaces: four leading spaces in the spec
stand for one tab, which is the indentation style of ctfedebug.d.
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.normpath(os.path.join(HERE, "..", "ctfedebug.d"))
SPECS = []


def read_lines(path):
    """Returns (lines, newline) with tabs converted to four space groups."""
    with io.open(path, "r", newline="") as f:
        text = f.read()
    nl = "\r\n" if "\r\n" in text else "\n"
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    return lines, nl


def spec_blocks(path):
    lines, _ = read_lines(path)
    blocks = []
    mode = None
    old = new = None
    for line in lines:
        tag = line.strip()
        if tag == "<<<OLD":
            old, new, mode = [], [], "old"
        elif tag == "<<<NEW":
            new, mode = [], "new"
        elif tag == "<<<END":
            assert old is not None and new is not None, "malformed block in " + path
            blocks.append((trim(old), trim(new)))
            old = new = None
            mode = None
        elif mode == "old":
            old.append(line)
        elif mode == "new":
            new.append(line)
        else:
            assert not line.strip() or line.startswith("#"), "stray line %r in %s" % (line, path)
    return blocks


def trim(lines):
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def to_tabs(lines):
    """Converts the four space indentation of the spec into tabs."""
    result = []
    for line in lines:
        stripped = line.lstrip(" ")
        indent = len(line) - len(stripped)
        assert indent % 4 == 0, "indentation is not a multiple of four: %r" % line
        result.append("\t" * (indent // 4) + stripped)
    return result


def pattern(lines):
    parts = []
    for line in lines:
        body = line.strip()
        parts.append("[ \\t]*" + re.escape(body) if body else "[ \\t]*")
    return NL.join(parts).replace(NL, r"\r?\n")


def apply_edit(text, old, new, what):
    pat = pattern(old)
    matches = list(re.finditer(pat, text))
    if len(matches) != 1:
        raise SystemExit("%s: anchor matched %d times:\n%s" % (what, len(matches), "\n".join(old[:4])))

    m = matches[0]
    ws = re.match(r"[ \t]*", text[m.start():]).group(0)
    base = re.match(r"[ \t]*", to_tabs(old)[0]).group(0)

    out = []
    for line in to_tabs(new):
        if line.startswith(base) and base:
            out.append(ws + line[len(base):])
        elif not line.strip():
            out.append("")
        else:
            out.append(line)

    return text[:m.start()] + NL.join(out) + text[m.end():]


lines, NL = read_lines(PATH)
text = NL.join(lines)

SPECS = [s if os.path.isabs(s) else os.path.join(HERE, s) for s in (sys.argv[1:] or SPECS)]
for spec in SPECS:
    for i, (old, new) in enumerate(spec_blocks(spec)):
        text = apply_edit(text, old, new, "%s block %d" % (spec, i))

with io.open(PATH, "w", newline="") as f:
    f.write(text)

print("patched %s" % PATH)
