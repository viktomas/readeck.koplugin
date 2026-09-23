#!/usr/bin/env python3
"""Picks annotation ranges in a Readeck article, independently of the plugin.

    annotation_oracle.py ARTICLE.html --count 25 --seed 1  > ranges.json

Reads the article HTML Readeck stores (GET /api/bookmarks/<id>/article) and
prints a JSON list of annotation payloads the way Readeck's web reader makes
them (read in ../readeck, pkg/annotate and the web reader):

- the selector is an XPath relative to <body>, naming the *element that holds
  the selected text node*, with an index on every step counted among
  same-named siblings;
- the offset counts Unicode code points over all descendant text of that
  element, raw (whitespace as stored, entities decoded).

About half of the ranges end in a later text node than they start (crossing
inline markup or into the next block). Ranges never overlap. This is the
oracle for e2e/tests/realworld_test.lua, so it deliberately shares no code
with readeck/annotations/position_map.lua.
"""

import argparse
import html.parser
import json
import random
import re

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
# Text inside these is not what a reader selects.
SKIP = {"script", "style", "noscript", "svg", "math", "head", "title"}


class Text(str):
    """A text node; compared by identity, never by value."""

    __slots__ = ()
    __hash__ = object.__hash__
    __eq__ = object.__eq__


class Node:
    def __init__(self, tag, parent):
        self.tag = tag
        self.parent = parent
        self.children = []  # Node or str


class Builder(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("body", None)
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, self.stack[-1])
        self.stack[-1].children.append(node)
        if tag not in VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.stack[-1].children.append(Node(tag, self.stack[-1]))

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        self.stack[-1].children.append(Text(data))


def selector(node):
    steps = []
    while node.parent is not None:
        same = [c for c in node.parent.children if isinstance(c, Node) and c.tag == node.tag]
        steps.append("%s[%d]" % (node.tag, same.index(node) + 1))
        node = node.parent
    return "/".join(reversed(steps))


def text_nodes(root):
    """Every text node in document order as (parent, text, offset_in_parent)."""
    out = []

    def walk(node, skipped):
        for child in node.children:
            if isinstance(child, Node):
                walk(child, skipped or child.tag in SKIP)
            elif not skipped:
                out.append([node, child])

    walk(root, False)
    # Offset of each text node within its parent's full descendant text.
    for entry in out:
        parent, text = entry
        before = 0
        found = False

        def count(node):
            nonlocal before, found
            for child in node.children:
                if found:
                    return
                if isinstance(child, Node):
                    count(child)
                elif child is text:
                    found = True
                    return
                else:
                    before += len(child)

        count(parent)
        entry.append(before)
    return out


def units(text):
    """Selectable units: words, or single characters in unspaced (CJK) text."""
    found = list(re.finditer(r"\S+", text))
    if len(found) < 3 and len(text.strip()) >= 12:
        found = list(re.finditer(r"\S", text))
    return found


def word_starts(text):
    return [m.start() for m in units(text)]


def word_ends(text):
    return [m.end() for m in units(text)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("html")
    ap.add_argument("--count", type=int, default=25)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    builder = Builder()
    with open(args.html, encoding="utf-8") as fh:
        builder.feed(fh.read())
    nodes = text_nodes(builder.root)
    usable = [i for i, (_, text, _) in enumerate(nodes) if len(word_starts(text)) >= 3]
    rng.shuffle(usable)

    used = set()
    ranges = []
    for i in usable:
        if len(ranges) >= args.count:
            break
        cross = rng.random() < 0.5 and i + 1 < len(nodes)
        j = i
        if cross:
            # The next text node that has words in it, not too far away.
            for k in range(i + 1, min(i + 6, len(nodes))):
                if word_ends(nodes[k][1]):
                    j = k
                    break
        if any(n in used for n in range(i - 1, j + 2)):
            continue
        start_parent, start_text, start_base = nodes[i]
        end_parent, end_text, end_base = nodes[j]
        starts = word_starts(start_text)
        s = rng.choice(starts[: max(1, len(starts) - 2)])
        if j == i:
            ends = [e for e in word_ends(start_text) if e > s]
            e = rng.choice(ends[: 8] if len(ends) <= 40 else ends[4:20])
        else:
            e = rng.choice(word_ends(end_text)[:3])
        ranges.append(
            {
                "start_selector": selector(start_parent),
                "start_offset": start_base + s,
                "end_selector": selector(end_parent),
                "end_offset": end_base + e,
                "crosses_nodes": j != i,
            }
        )
        used.update(range(i, j + 1))

    print(json.dumps(ranges, ensure_ascii=False))


if __name__ == "__main__":
    main()
