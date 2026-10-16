#!/usr/bin/env python3
"""Download public datasets and generate compact lookup tables for LanDetectorKit.

Sources (all public / open source):
  * IEEE Registration Authority – MA-L, MA-M, MA-S, IAB, CID registries
  * IANA Service Name and Transport Protocol Port Number Registry
  * AppleDB (https://appledb.dev, MIT licensed) – Apple model identifiers

Usage:  python3 Scripts/update_data.py [--cache DIR]
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "Packages", "LanDetectorKit", "Sources", "LanDetectorKit", "Resources")

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/18.0 Safari/605.1.15")

IEEE = {
    "MA-L": "https://standards-oui.ieee.org/oui/oui.csv",
    "MA-M": "https://standards-oui.ieee.org/oui28/mam.csv",
    "MA-S": "https://standards-oui.ieee.org/oui36/oui36.csv",
    "IAB": "https://standards-oui.ieee.org/iab/iab.csv",
    "CID": "https://standards-oui.ieee.org/cid/cid.csv",
}
IANA = "https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.csv"
APPLEDB = "https://api.appledb.dev/device/main.json"

# AppleDB device types that can actually show up on a network.
APPLE_TYPES = {
    "AirPort", "Apple TV", "Apple Watch", "HomePod", "Mac Pro", "Mac Studio", "Mac mini",
    "MacBook", "MacBook Air", "MacBook Neo", "MacBook Pro", "iMac", "iPad", "iPad Air",
    "iPad Pro", "iPad mini", "iPhone", "iPod touch", "Headset", "Xserve", "Display",
    "Virtual Machine", "Compute Module",
}


def fetch(url: str, cache: str | None) -> bytes:
    if cache:
        path = os.path.join(cache, url.rstrip("/").split("/")[-1])
        if os.path.exists(path):
            with open(path, "rb") as f:
                return f.read()
    print(f"  ↓ {url}", file=sys.stderr)
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = resp.read()
    if cache:
        os.makedirs(cache, exist_ok=True)
        with open(os.path.join(cache, url.rstrip("/").split("/")[-1]), "wb") as f:
            f.write(data)
    return data


def clean(text: str) -> str:
    return " ".join(text.replace("\t", " ").split()).strip()


def build_oui(cache: str | None) -> None:
    entries: dict[str, str] = {}
    counts = {}
    for registry, url in IEEE.items():
        rows = csv.DictReader(io.StringIO(fetch(url, cache).decode("utf-8", "replace")))
        n = 0
        for row in rows:
            prefix = (row.get("Assignment") or "").strip().upper()
            name = clean(row.get("Organization Name") or "")
            if not prefix or not name or name.lower() == "private":
                continue
            if name == "IEEE Registration Authority":
                continue  # parent blocks of MA-M / MA-S assignments
            entries.setdefault(prefix, name)
            n += 1
        counts[registry] = n
    path = os.path.join(OUT_DIR, "oui.tsv")
    with open(path, "w", encoding="utf-8") as f:
        for prefix in sorted(entries):
            f.write(f"{prefix}\t{entries[prefix]}\n")
    print(f"oui.tsv: {len(entries)} prefixes {counts}")


def build_ports(cache: str | None) -> None:
    rows = csv.DictReader(io.StringIO(fetch(IANA, cache).decode("utf-8", "replace")))
    tcp: dict[int, tuple[str, str]] = {}
    for row in rows:
        if (row.get("Transport Protocol") or "").strip().lower() != "tcp":
            continue
        port = (row.get("Port Number") or "").strip()
        if not port.isdigit():
            continue
        name = clean(row.get("Service Name") or "")
        desc = clean(row.get("Description") or "")
        if not name or desc.lower() in ("reserved", "unassigned"):
            continue
        p = int(port)
        if p not in tcp:
            tcp[p] = (name, desc)
    path = os.path.join(OUT_DIR, "ports.tsv")
    with open(path, "w", encoding="utf-8") as f:
        for p in sorted(tcp):
            name, desc = tcp[p]
            f.write(f"{p}\t{name}\t{desc}\n")
    print(f"ports.tsv: {len(tcp)} tcp ports")


def build_apple(cache: str | None) -> None:
    items = json.loads(fetch(APPLEDB, cache))
    out: dict[str, tuple[str, str]] = {}
    for item in items:
        kind = item.get("type") or ""
        if kind not in APPLE_TYPES:
            continue
        ids = item.get("identifier") or []
        if isinstance(ids, str):
            ids = [ids]
        name = clean(item.get("name") or "")
        if not name:
            continue
        for ident in ids:
            ident = ident.strip()
            # Prefer the most generic marketing name, e.g. "HomePod mini" over
            # "HomePod mini (China Mainland)".
            if ident and "," in ident and (ident not in out or len(name) < len(out[ident][0])):
                out[ident] = (name, kind)
    path = os.path.join(OUT_DIR, "apple-models.tsv")
    with open(path, "w", encoding="utf-8") as f:
        for ident in sorted(out):
            name, kind = out[ident]
            f.write(f"{ident}\t{name}\t{kind}\n")
    print(f"apple-models.tsv: {len(out)} identifiers")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", help="directory with previously downloaded source files")
    args = parser.parse_args()
    os.makedirs(OUT_DIR, exist_ok=True)
    build_oui(args.cache)
    build_ports(args.cache)
    build_apple(args.cache)


if __name__ == "__main__":
    main()
