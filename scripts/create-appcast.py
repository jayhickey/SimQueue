#!/usr/bin/env python3
"""Generate a stable update feed; signatures are produced by Sparkle's signer."""
import argparse
import base64
import re
from pathlib import Path
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def create(version, archive, signature, repository):
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", version):
        raise ValueError("Only stable semantic versions belong in the default feed")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", repository):
        raise ValueError("Invalid repository")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid Ed25519 signature")
    expected = f"SimQueue-{version}.zip"
    if archive.name != expected or not archive.is_file():
        raise ValueError("Unexpected update archive")
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "SimQueue updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"SimQueue {version}"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
    ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink").text = f"https://github.com/{repository}/releases/tag/v{version}"
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{repository}/releases/download/v{version}/{archive.name}",
        "length": str(archive.stat().st_size), "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": signature,
    })
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("archive", type=Path)
    parser.add_argument("signature")
    parser.add_argument("output", type=Path)
    parser.add_argument("--repository", default="jayhickey/SimQueue")
    args = parser.parse_args()
    args.output.write_bytes(create(args.version, args.archive, args.signature, args.repository))
