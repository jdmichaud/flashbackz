#!/usr/bin/env python3
"""Checks the format documents in docs/formats/.

The documents form a tree: README is the root, and the documents that its lists of files link
are its children, in the order of the links. The walk visits README, then the children. The
Terms section of README is a glossary: a term that it defines is defined for all of it, and its
list of words with one meaning gives naming rules, not uses.

Checks:
- each link to a document or to a heading exists;
- a prose line has at most 100 columns (tables and code blocks can be longer);
- no modal verb that Simplified Technical English refuses;
- no retired name (each thing has one name);
- each agreed term has its definition at or before its first use in the walk.

Usage: check_format_docs.py [DIRECTORY]
       check_format_docs.py --first REGEX [DIRECTORY]   (print the first use in the walk)
"""
import pathlib
import re
import sys

WIDTH = 100

MODAL_VERBS = re.compile(r"\b(should|shall|may|might|will|would|could)\b", re.IGNORECASE)

# Each retired name, with the name that replaces it.
RETIRED = [
    (r"final films?", "the ending"),
    (r"end sequence", "the ending"),
    (r"final scene list", "the ending list"),
    (r"level scene", "the level screen"),
    (r"level font", "the game font"),
    (r"inventory font", "the game font"),
    (r"backward codec", "the packed stream"),
    (r"(?<!level )\bloader\b", "the reader"),
    (r"bank slot", "the palette slot"),
    (r"palette banks?", "the color block, the PAL bank or the palette slot"),
    (r"game update", "the host frame"),
    (r"active character", "an awake character"),
    (r"REminiscence", "no third-party reimplementation"),
]

# Each agreed term: its name, a pattern of its uses, and a pattern of its definition. The
# definition must be at or before the first use in the walk.
TERMS = [
    ("host", r"\bhosts?\b", r"^- \*\*Host\*\*:"),
    ("extractor", r"\bextractor\b", r"^- \*\*Extractor\*\*:"),
    ("atlas", r"\batlas\b", r"^- \*\*Atlas\*\*:"),
    ("flashback-re", r"\bflashback-re\b", r"^- \*\*flashback-re\*\*:"),
    ("state", r"\bstates?\b", r"^- \*\*State\*\*:"),
    ("rule", r"\brules?\b", r"^- \*\*Rule\*\*:"),
    ("condition", r"\bconditions?\b", r"^- \*\*Condition\*\*"),
    ("effect", r"(?<!sound )\beffects?\b", r"^- \*\*Condition\*\*, \*\*effect\*\*"),
    ("operation", r"\boperations?\b", r"\*\*operation\*\*:"),
    ("demo", r"\bdemos?\b", r"^- \*\*Demo\*\*:"),
    ("update", r"\bupdates?\b", r"^- \*\*Update\*\*:"),
    ("host frame", r"\bhost frames?\b", r"^- \*\*Host frame\*\*:"),
    ("tick", r"\bticks?\b", r"^- \*\*Tick\*\*:"),
    ("scene", r"\bscenes?\b", r"^- \*\*Scene\*\*:"),
    ("asset path", r"\basset paths?\b", r"An asset path is"),
    ("asset source", r"\basset source\b", r"is the asset source:"),
    ("provider", r"\bproviders?\b", r"A provider is"),
    ("standalone build", r"\bstandalone build\b", r"The standalone build \(`flashbackz-"),
    ("trailer", r"\btrailer\b", r"The trailer of the\s*$"),
    ("color block", r"\bcolor blocks?\b", r"A color block is"),
    ("PAL bank", r"\bPAL banks?\b", r"A PAL bank is"),
    ("palette slot", r"\bpalette slots?\b", r"A palette slot is"),
    ("music cue", r"\b(music )?cues?\b", r"A music cue is"),
    ("film entry", r"\bfilm entr(y|ies)\b", r"A film can hold several film entries"),
    ("level code", r"\blevel codes?\b", r"The player types a level code"),
    ("tile bias", r"\btile bias\b", r"bias is a number that the reader subtracts"),
    ("engine", r"\bengine\b", r"^The engine is the part of the game"),
    ("terrain cell", r"\bterrain cells?\b", r"^- \*\*Cell\*\*: a terrain cell"),
    ("sight scan", r"\bsight scans?\b", r"^A sight scan is"),
    ("awake", r"\b(awake|asleep)\b", r"An awake character runs"),
    ("view room", r"\bview room\b", r"The view room is"),
    ("cursor", r"\bcursor\b", r"The cursor is the index"),
    ("fire", r"\b(fires?|fired)\b", r"A rule fires when"),
    ("message", r"(?<!world )\bmessages?\b", r"^A message is a signal"),
    ("contact", r"\bcontacts?\b", r"and have a contact, when"),
    ("contact slot", r"\bcontact slots?\b", r"A contact slot is"),
    ("footprint", r"\bfootprints?\b", r"These cells are its footprint"),
    ("touch label", r"\btouch label\b", r"The touch label shows the name"),
    ("carrier", r"\bcarriers?\b", r"A carrier is a character"),
    ("hit", r"\bhits?\b", r"^A hit is the message"),
    ("renderer", r"\brenderer\b", r"The renderer is"),
    ("level loader", r"\blevel loader\b", r"The level loader is"),
    ("composition", r"\bcompositions?\b", r"A composition is"),
    ("selected item", r"\bselected item\b", r"The selected item is"),
    ("replay mode", r"\breplay mode\b", r"in replay mode: each picture shows"),
    ("player", r"\b(film|music|tune) player\b|\bthe player of\b", r"The film player is the code"),
    ("first cell", r"\bfirst cell\b", r"The first cell of a character is"),
    ("look", r"\blook\b(?! (for|at|in|up))", r"The look of a character is"),
    ("protection", r"\bprotection\b", r"Protection is"),
    ("world", r"\bthe world\b(?! messages?)", r"The world is"),
    ("session", r"(?<!trace )\bsessions?\b", r"The session is"),
    ("storage", r"\bstorage\b", r"The storage keeps the saves"),
    ("options dialog", r"\boptions dialog\b", r"The options dialog is"),
    ("checkpoint", r"\bcheckpoints?\b", r"A checkpoint is"),
    ("letter", r"(?<!ASCII )\bletters?\b(?!,| or\b)", r"A letter is"),
    ("pad model", r"\bpad models?\b", r"A pad model is"),
    ("platform", r"(?<!`)\bplatform\b(?!\.zig)", r"The platform is"),
]


def walk(directory):
    """README, then the documents that the lists of files of README link, in link order."""
    readme = directory / "README.md"
    order = [readme]
    files = readme.read_text().split("\n## The original's files", 1)[1]
    for target in re.findall(r"\]\(([a-z0-9-]+\.md)[^)]*\)", files):
        path = directory / target
        if path not in order:
            order.append(path)
    return order


def blocks(path):
    """For each line number: (the first line of its block, the kind of the line).

    A block is a paragraph, a list item, a heading or a whole table. In README, the Terms
    section is one block (a glossary), and its lists of words are naming rules, not uses.
    """
    result = {}
    start = None
    previous = None
    glossary = None
    rules = False
    for number, text, kind in lines_of(path):
        if path.name == "README.md" and text == "## Terms":
            glossary = number
        elif text.startswith("## "):
            glossary = None
        if text.startswith("Some words have several kinds"):
            rules = True
        elif text.startswith("The documents use the terms of these standards"):
            rules = False
        item = re.match(r"\s*(- |\d+\. )", text)
        if not text.strip():
            start = None
        elif start is None or kind == "heading" or item:
            start = number
        elif (kind == "table") != (previous == "table"):
            start = number
        previous = kind
        result[number] = (glossary or start, "rules" if rules else kind)
    return result


def prose(line):
    """The line without its inline code spans, its link targets and its file names."""
    line = re.sub(r"`[^`]*`", "", line)
    line = re.sub(r"\]\([^)]*\)", "]", line)
    return re.sub(r"\[[\w-]+\.md\]", "[]", line)


def lines_of(path):
    """(number, text, kind) for each line; kind is "code", "table", "heading" or "prose"."""
    fenced = False
    result = []
    for number, text in enumerate(path.read_text().split("\n"), 1):
        if text.lstrip().startswith("```"):
            fenced = not fenced
            result.append((number, text, "code"))
        elif fenced:
            result.append((number, text, "code"))
        elif text.lstrip().startswith("|"):
            result.append((number, text, "table"))
        elif text.startswith("#"):
            result.append((number, text, "heading"))
        else:
            result.append((number, text, "prose"))
    return result


def anchors(path):
    """The GitHub anchors of the headings of a document."""
    seen = {}
    result = set()
    for _, text, kind in lines_of(path):
        if kind != "heading":
            continue
        slug = text.lstrip("#").strip().lower()
        slug = re.sub(r"[^\w\- ]", "", slug).replace(" ", "-")
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        result.add(slug if count == 0 else f"{slug}-{count}")
    return result


def check(directory):
    failures = []
    documents = sorted(directory.glob("*.md"))
    for path in documents:
        for number, text, kind in lines_of(path):
            where = f"{path.name}:{number}"
            if kind == "prose" and len(text) > WIDTH:
                failures.append(f"{where}: {len(text)} columns")
            if kind == "code":
                continue
            for target, anchor in re.findall(r"\]\(([^)#\s]*)(?:#([^)\s]*))?\)", text):
                if target.startswith(("http://", "https://")):
                    continue
                linked = directory / target if target else path
                if not linked.exists():
                    if not (directory / target).resolve().exists():
                        failures.append(f"{where}: no file {target}")
                    continue
                if anchor and linked.suffix == ".md" and anchor not in anchors(linked):
                    failures.append(f"{where}: no heading #{anchor} in {linked.name}")
            words = prose(text)
            for match in MODAL_VERBS.finditer(words):
                failures.append(f"{where}: modal verb '{match.group(0)}'")
            for pattern, replacement in RETIRED:
                for match in re.finditer(pattern, words, re.IGNORECASE):
                    failures.append(f"{where}: '{match.group(0)}', use {replacement}")
    order = walk(directory)
    missing = [path.name for path in documents if path not in order]
    if missing:
        failures.append(f"README links no {', '.join(missing)}")
    for name, use, definition in TERMS:
        first = first_match(order, use, prose_only=True)
        defined = first_match(order, definition, prose_only=False, case=True)
        if defined is None:
            failures.append(f"term '{name}': no definition")
        elif first is not None and first[0] < defined[0]:
            failures.append(
                f"term '{name}': used at {first[1]} before its definition at {defined[1]}"
            )
    return failures


def first_match(order, pattern, prose_only, case=False):
    """((document index, block start), 'file:line') of the first match in the walk."""
    flags = 0 if case else re.IGNORECASE
    for index, path in enumerate(order):
        starts = blocks(path)
        for number, text, kind in lines_of(path):
            if kind in ("code", "heading"):
                continue
            if prose_only and starts[number][1] == "rules":
                continue
            words = prose(text) if prose_only else text
            if re.search(pattern, words, flags):
                return ((index, starts[number][0]), f"{path.name}:{number}")
    return None


def main(arguments):
    if arguments[:1] == ["--first"]:
        directory = pathlib.Path(arguments[2] if len(arguments) > 2 else "docs/formats")
        found = first_match(walk(directory), arguments[1], prose_only=True)
        print(found[1] if found else "no use")
        return 0
    directory = pathlib.Path(arguments[0] if arguments else "docs/formats")
    failures = check(directory)
    for failure in failures:
        print(failure)
    print(f"check_format_docs: {len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
