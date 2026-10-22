#!/usr/bin/env python3
"""The Sparkle feed a release publishes beside its DMG (see appcast.sh and release.sh). Standard library only, Python 3.9.

  appcast.py render --version V --build N --url U --length L --signature S --notes FILE --min-os 14.0 [--date D] --out FILE
  appcast.py check FILE --version V --build N --url U --length L --signature S
  appcast.py max-build FILE      the highest sparkle:version in a feed, 0 when it has no item
"""
import argparse
import base64
import re
import sys
import time
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


class Invalid(ValueError):
    pass


def _validate(version, build, url, length, signature):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise Invalid(f"version {version!r} isn't like 1.2.3")
    # Sparkle compares sparkle:version with the running app's CFBundleVersion.
    if not re.fullmatch(r"[1-9]\d*", build):
        raise Invalid(f"build {build!r} isn't a plain number")
    if not (url.startswith("https://") or url.startswith("http://127.0.0.1:")):
        raise Invalid(f"url {url!r} isn't https")
    if not re.fullmatch(r"[1-9]\d*", str(length)):
        raise Invalid(f"length {length!r} isn't a size")
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise Invalid("the signature isn't 64 bytes")
    except ValueError as error:
        raise Invalid(f"the signature isn't base64: {error}")


def _min_os(value):
    parts = value.split(".")
    if not all(p.isdigit() for p in parts) or not 1 <= len(parts) <= 3:
        raise Invalid(f"minimum macOS {value!r}")
    return ".".join(parts + ["0"] * (3 - len(parts)))


def _cdata(text):
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def _escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def render(version, build, url, length, signature, notes, min_os, date=None):
    """One item, for one release: GitHub serves the feed of the latest release only."""
    _validate(version, build, url, length, signature)
    date = date or time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime())
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE}">
  <channel>
    <title>Nunsseop</title>
    <link>https://namekun.github.io/Nunsseop/</link>
    <description>Nunsseop updates</description>
    <language>en</language>
    <item>
      <title>{version}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{_min_os(min_os)}</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <sparkle:fullReleaseNotesLink>https://github.com/namekun/Nunsseop/releases/tag/v{version}</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown">{_cdata(notes.strip())}</description>
      <enclosure url="{_escape(url)}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
"""


def items(text):
    return ET.fromstring(text).findall("./channel/item")


def check(text, version, build, url, length, signature):
    """The fields a release promised, read back from the file it is about to publish."""
    found = items(text)
    if len(found) != 1:
        raise Invalid(f"{len(found)} items, expected 1")
    item = found[0]
    enclosure = item.find("enclosure")
    actual = {
        "version": item.findtext(f"{{{SPARKLE}}}shortVersionString"),
        "build": item.findtext(f"{{{SPARKLE}}}version"),
        "url": enclosure.get("url") if enclosure is not None else None,
        "length": enclosure.get("length") if enclosure is not None else None,
        "signature": enclosure.get(f"{{{SPARKLE}}}edSignature") if enclosure is not None else None,
    }
    expected = {"version": version, "build": build, "url": url, "length": str(length), "signature": signature}
    wrong = [f"{key} is {actual[key]!r}, expected {value!r}" for key, value in expected.items() if actual[key] != value]
    if wrong:
        raise Invalid("; ".join(wrong))


def max_build(text):
    builds = [item.findtext(f"{{{SPARKLE}}}version") or "" for item in items(text)]
    return max([int(b) for b in builds if b.isdigit()], default=0)


def main(argv):
    parser = argparse.ArgumentParser(prog="appcast.py")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("render", "check"):
        command = commands.add_parser(name)
        if name == "check":
            command.add_argument("file")
        for option in ("--version", "--build", "--url", "--length", "--signature"):
            command.add_argument(option, required=True)
        if name == "render":
            command.add_argument("--notes", required=True)
            command.add_argument("--min-os", required=True)
            command.add_argument("--date")
            command.add_argument("--out", required=True)
    commands.add_parser("max-build").add_argument("file")
    args = parser.parse_args(argv)
    try:
        if args.command == "render":
            with open(args.notes, encoding="utf-8") as notes:
                text = render(args.version, args.build, args.url, args.length, args.signature, notes.read(), args.min_os, args.date)
            ET.fromstring(text)
            with open(args.out, "w", encoding="utf-8") as out:
                out.write(text)
        elif args.command == "check":
            with open(args.file, encoding="utf-8") as feed:
                check(feed.read(), args.version, args.build, args.url, args.length, args.signature)
        else:
            with open(args.file, encoding="utf-8") as feed:
                print(max_build(feed.read()))
    except (Invalid, ET.ParseError) as error:
        print(f"appcast.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
