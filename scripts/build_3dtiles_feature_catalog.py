#!/usr/bin/env python3
"""Build a static identifier-to-GLB catalog for frontend 3D hull analysis."""

from __future__ import annotations

import argparse
import json
import struct
from collections import defaultdict
from pathlib import Path


def parse_glb(path: Path) -> tuple[dict, memoryview]:
    data = path.read_bytes()
    magic, version, _ = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67 or version != 2:
        raise ValueError(f"Unsupported GLB: {path}")
    offset = 12
    document = None
    binary = None
    while offset + 8 <= len(data):
        length, chunk_type = struct.unpack_from("<II", data, offset)
        start = offset + 8
        chunk = memoryview(data)[start : start + length]
        if chunk_type == 0x4E4F534A:
            document = json.loads(bytes(chunk).decode("utf-8").rstrip("\x00 \t\r\n"))
        elif chunk_type == 0x004E4942:
            binary = chunk
        offset = start + length
    if document is None or binary is None:
        raise ValueError(f"Missing JSON or BIN chunk: {path}")
    return document, binary


def view_bytes(document: dict, binary: memoryview, index: int) -> memoryview:
    view = document["bufferViews"][index]
    start = view.get("byteOffset", 0)
    return binary[start : start + view["byteLength"]]


def decode_strings(document: dict, binary: memoryview, property_: dict, count: int) -> list[str]:
    values = view_bytes(document, binary, property_["values"])
    offsets = view_bytes(document, binary, property_["stringOffsets"])
    width = len(offsets) // (count + 1)
    formats = {1: "B", 2: "H", 4: "I", 8: "Q"}
    if width not in formats:
        raise ValueError(f"Unsupported string offset width: {width}")
    unpacked = struct.unpack_from(f"<{count + 1}{formats[width]}", offsets)
    return [bytes(values[unpacked[i] : unpacked[i + 1]]).decode("utf-8") for i in range(count)]


def content_identifiers(path: Path) -> tuple[list[str], set[str]]:
    document, binary = parse_glb(path)
    metadata = document.get("extensions", {}).get("EXT_structural_metadata", {})
    aliases: list[str] = []
    primary_ids: set[str] = set()
    for table in metadata.get("propertyTables", []):
        schema_class = metadata.get("schema", {}).get("classes", {}).get(table.get("class"), {})
        definitions = schema_class.get("properties", {})
        for name, property_ in table.get("properties", {}).items():
            definition = definitions.get(name, {})
            if definition.get("type") != "STRING" and "stringOffsets" not in property_:
                continue
            values = decode_strings(document, binary, property_, table["count"])
            if name == "id":
                primary_ids.update(value for value in values if value)
            if name in {"id", "objectid", "identifier", "gen_osmurl"}:
                aliases.extend(value for value in values if value)
    return aliases, primary_ids


def build_catalog(tileset_path: Path) -> dict:
    root = tileset_path.parent
    features: dict[str, list[str]] = defaultdict(list)
    content_count = 0
    primary_ids: set[str] = set()
    for glb_path in sorted(root.rglob("*.glb")):
        identifiers, content_primary_ids = content_identifiers(glb_path)
        uri = glb_path.relative_to(root).as_posix()
        content_count += 1
        primary_ids.update(content_primary_ids)
        for identifier in identifiers:
            if uri not in features[identifier]:
                features[identifier].append(uri)
    tileset = json.loads(tileset_path.read_text(encoding="utf-8"))
    return {
        "version": 1,
        "tileset": tileset_path.name,
        "tileTransform": tileset.get("root", {}).get("transform"),
        "gltfUpAxis": tileset.get("asset", {}).get("gltfUpAxis", "Y"),
        "featureCount": len(primary_ids),
        "contentCount": content_count,
        "features": dict(sorted(features.items())),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tileset", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    catalog = build_catalog(args.tileset.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(
        f"Wrote {args.output}: {catalog['featureCount']} features in "
        f"{catalog['contentCount']} GLB files"
    )


if __name__ == "__main__":
    main()
