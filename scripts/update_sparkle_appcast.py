#!/usr/bin/env python3

import argparse
from datetime import datetime, timezone
from pathlib import Path
import xml.etree.ElementTree as ET

NS_SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS_DC = "http://purl.org/dc/elements/1.1/"


ET.register_namespace("sparkle", NS_SPARKLE)
ET.register_namespace("dc", NS_DC)


def sparkle_tag(name: str) -> str:
    return f"{{{NS_SPARKLE}}}{name}"


def build_pub_date(raw: str | None) -> str:
    if raw:
        return raw
    return datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")


def load_or_create_feed(path: Path, title: str, link: str, description: str) -> ET.ElementTree:
    if path.exists():
        return ET.parse(path)

    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = title
    ET.SubElement(channel, "link").text = link
    ET.SubElement(channel, "description").text = description
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(root)


def normalize_channel_metadata(channel: ET.Element, title: str, link: str, description: str) -> None:
    def ensure_child(tag: str, value: str) -> None:
        node = channel.find(tag)
        if node is None:
            node = ET.SubElement(channel, tag)
        if not (node.text or "").strip():
            node.text = value

    ensure_child("title", title)
    ensure_child("link", link)
    ensure_child("description", description)
    ensure_child("language", "en")


def remove_existing_item(channel: ET.Element, short_version: str, bundle_version: str) -> None:
    for item in list(channel.findall("item")):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue

        existing_short = enclosure.attrib.get(sparkle_tag("shortVersionString"), "")
        existing_build = enclosure.attrib.get(sparkle_tag("version"), "")

        if existing_short == short_version and existing_build == bundle_version:
            channel.remove(item)


def insert_item(channel: ET.Element, item: ET.Element) -> None:
    children = list(channel)
    insert_index = len(children)
    for index, child in enumerate(children):
        if child.tag == "item":
            insert_index = index
            break
    channel.insert(insert_index, item)


def main() -> int:
    parser = argparse.ArgumentParser(description="Create or update Sparkle appcast.xml")
    parser.add_argument("--appcast", default="appcast.xml")
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--build", required=True, help="CFBundleVersion")
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--signature", required=True, help="sparkle:edSignature value")
    parser.add_argument("--length", type=int, required=True)
    parser.add_argument("--release-notes-url", default="")
    parser.add_argument("--minimum-system-version", default="")
    parser.add_argument("--pub-date", default="")
    parser.add_argument("--title", default="")
    parser.add_argument("--channel-title", default="Archive Updates")
    parser.add_argument("--channel-link", default="https://github.com/daniel-trachtenberg/archive-plugin/releases")
    parser.add_argument("--channel-description", default="Latest updates for Archive.")
    args = parser.parse_args()

    appcast_path = Path(args.appcast)
    item_title = args.title.strip() or f"Version {args.version}"
    pub_date = build_pub_date(args.pub_date.strip() or None)

    tree = load_or_create_feed(
        path=appcast_path,
        title=args.channel_title,
        link=args.channel_link,
        description=args.channel_description,
    )

    root = tree.getroot()
    if root.tag != "rss":
        raise ValueError("appcast root element must be <rss>")

    channel = root.find("channel")
    if channel is None:
        channel = ET.SubElement(root, "channel")

    normalize_channel_metadata(channel, args.channel_title, args.channel_link, args.channel_description)
    remove_existing_item(channel, args.version, args.build)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = item_title
    ET.SubElement(item, "pubDate").text = pub_date

    enclosure_attrs = {
        "url": args.download_url,
        sparkle_tag("version"): args.build,
        sparkle_tag("shortVersionString"): args.version,
        sparkle_tag("edSignature"): args.signature,
        "length": str(args.length),
        "type": "application/octet-stream",
    }
    if args.minimum_system_version.strip():
        enclosure_attrs[sparkle_tag("minimumSystemVersion")] = args.minimum_system_version.strip()

    ET.SubElement(item, "enclosure", enclosure_attrs)

    if args.release_notes_url.strip():
        notes = ET.SubElement(item, sparkle_tag("releaseNotesLink"))
        notes.text = args.release_notes_url.strip()

    insert_item(channel, item)

    try:
        ET.indent(tree, space="  ")
    except AttributeError:
        pass

    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
