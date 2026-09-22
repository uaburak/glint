#!/usr/bin/env python3
"""Adds a release to Glint's Sparkle appcast.

Reads the previous appcast (if any), puts the new release on top and keeps the older entries,
so the feed lists every version. An entry with the same build number is replaced, which makes
re-running a release safe. Called by release.sh.
"""

import argparse
import email.utils
import os
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def sparkle(tag):
    return f"{{{SPARKLE}}}{tag}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous", help="the appcast currently published, if there is one")
    parser.add_argument("--out", required=True)
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString, e.g. 1.2")
    parser.add_argument("--build", required=True, help="CFBundleVersion, the number Sparkle compares")
    parser.add_argument("--minimum-system", required=True)
    parser.add_argument("--url", required=True, help="where the DMG is downloaded from")
    parser.add_argument("--length", required=True)
    parser.add_argument("--signature", required=True, help="EdDSA signature from sign_update")
    parser.add_argument("--link", help="the release's web page")
    parser.add_argument("--notes", help="release notes, Markdown")
    args = parser.parse_args()

    if args.previous and os.path.exists(args.previous):
        tree = ET.parse(args.previous)
        channel = tree.getroot().find("channel")
    else:
        root = ET.Element("rss", {"version": "2.0"})
        tree = ET.ElementTree(root)
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Glint"
        ET.SubElement(channel, "description").text = "Glint güncellemeleri"
        ET.SubElement(channel, "language").text = "tr"

    for old in channel.findall("item"):
        if old.findtext(sparkle("version")) == args.build:
            channel.remove(old)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.version
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, sparkle("version")).text = args.build
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.minimum_system
    if args.link:
        ET.SubElement(item, "link").text = args.link
    if args.notes:
        with open(args.notes, encoding="utf-8") as notes:
            description = ET.SubElement(item, "description", {sparkle("descriptionFormat"): "markdown"})
            description.text = notes.read().strip()
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": args.length,
        "type": "application/octet-stream",
        sparkle("edSignature"): args.signature,
    })

    # Newest first, after the channel's own title/description/language.
    first_item = next((i for i, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(first_item, item)

    ET.indent(tree, space="    ")
    tree.write(args.out, encoding="utf-8", xml_declaration=True)
    count = len(channel.findall("item"))
    print(f"appcast: {args.version} ({args.build}) added, {count} release(s) listed", file=sys.stderr)


if __name__ == "__main__":
    main()
