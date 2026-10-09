#!/usr/bin/env python3
"""Adds one release to a Sparkle appcast (creates the file when there is none).

Used by Tools/release.sh after Sparkle's sign_update has signed the DMG. Standard library only.

    update_appcast.py --out appcast.xml [--existing old-appcast.xml] \
        --title "Camera Bridge 1.0" --short-version 1.0 --build 3 \
        --url https://github.com/OWNER/REPO/releases/download/v1.0/CameraBridge-1.0.dmg \
        --signature BASE64 --length 12345678 [--min-os 15.0] [--notes-url URL] [--date "RFC 2822 date"]

Items are keyed by the build number (sparkle:version): adding a build that is already in the feed replaces that item. Items
are sorted newest build first. Other items are kept exactly as they are.
"""
import argparse
import email.utils
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", DC)


def q(ns, name):
    return "{%s}%s" % (ns, name)


def build_number(item):
    value = item.findtext(q(SPARKLE, "version"))
    if value is None:
        enclosure = item.find("enclosure")
        value = enclosure.get(q(SPARKLE, "version")) if enclosure is not None else None
    try:
        return int(value)
    except (TypeError, ValueError):
        return -1


def new_item(args):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.title
    ET.SubElement(item, "pubDate").text = args.date or email.utils.formatdate(usegmt=True)
    ET.SubElement(item, q(SPARKLE, "version")).text = args.build
    ET.SubElement(item, q(SPARKLE, "shortVersionString")).text = args.short_version
    ET.SubElement(item, q(SPARKLE, "minimumSystemVersion")).text = args.min_os
    if args.notes_url:
        ET.SubElement(item, q(SPARKLE, "fullReleaseNotesLink")).text = args.notes_url
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("length", str(args.length))
    enclosure.set("type", "application/x-apple-diskimage")
    enclosure.set(q(SPARKLE, "edSignature"), args.signature)
    return item


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    parser.add_argument("--existing")
    parser.add_argument("--title", required=True)
    parser.add_argument("--short-version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--length", required=True, type=int)
    parser.add_argument("--min-os", default="15.0")
    parser.add_argument("--notes-url")
    parser.add_argument("--date")
    args = parser.parse_args()

    if not args.build.isdigit():
        sys.exit("error: --build must be the integer CFBundleVersion, got %r" % args.build)

    channel = None
    if args.existing:
        try:
            root = ET.parse(args.existing).getroot()
            channel = root.find("channel")
        except (OSError, ET.ParseError) as error:
            sys.exit("error: cannot read the existing appcast %s: %s" % (args.existing, error))
    if channel is None:
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Camera Bridge"
        ET.SubElement(channel, "link").text = "https://www.camera-bridge.app"
        ET.SubElement(channel, "description").text = "Camera Bridge updates"
        ET.SubElement(channel, "language").text = "en"

    items = [i for i in channel.findall("item") if build_number(i) != int(args.build)]
    items.append(new_item(args))
    items.sort(key=build_number, reverse=True)
    for old in channel.findall("item"):
        channel.remove(old)
    for item in items:
        channel.append(item)

    ET.indent(root, space="    ")
    ET.ElementTree(root).write(args.out, encoding="utf-8", xml_declaration=True)
    with open(args.out, "a", encoding="utf-8") as handle:
        handle.write("\n")
    print("appcast: %d item(s), newest build %s -> %s" % (len(items), build_number(items[0]), args.out))


if __name__ == "__main__":
    main()
