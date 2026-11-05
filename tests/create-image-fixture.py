#!/usr/bin/env python3
"""Create two Docker save-format images sharing a nonempty base layer.

The second image adds one layer. The test can remove its image metadata while
its daemon is stopped to simulate a layer left without an image reference.
"""

import argparse
import hashlib
import io
import json
import tarfile
from pathlib import Path


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode()


def add_file(archive, name, data):
    entry = tarfile.TarInfo(name)
    entry.mode = 0o644
    entry.size = len(data)
    entry.mtime = 0
    archive.addfile(entry, io.BytesIO(data))


def layer(path, contents):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        add_file(archive, path, contents)
    return output.getvalue()


def image_config(diff_ids):
    return json_bytes({
        "architecture": "amd64",
        "os": "linux",
        "config": {},
        "rootfs": {"type": "layers", "diff_ids": diff_ids},
        "history": [{"created_by": "foster integration fixture"} for _ in diff_ids],
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="output Docker image archive")
    args = parser.parse_args()

    base_layer = layer("base.txt", b"retained base layer\n")
    orphan_layer = layer("orphan.txt", b"unreferenced child layer\n")
    base_diff = digest(base_layer)
    orphan_diff = digest(orphan_layer)
    base_config = image_config([base_diff])
    orphan_config = image_config([base_diff, orphan_diff])
    base_image = digest(base_config)
    orphan_image = digest(orphan_config)
    base_tag, orphan_tag = "foster-fixture:base", "foster-fixture:orphan"

    manifest = [
        {"Config": base_image[7:] + ".json", "RepoTags": [base_tag], "Layers": ["base/layer.tar"]},
        {"Config": orphan_image[7:] + ".json", "RepoTags": [orphan_tag],
         "Layers": ["base/layer.tar", "orphan/layer.tar"]},
    ]
    with tarfile.open(args.output, "w", format=tarfile.USTAR_FORMAT) as archive:
        add_file(archive, "manifest.json", json_bytes(manifest))
        add_file(archive, base_image[7:] + ".json", base_config)
        add_file(archive, orphan_image[7:] + ".json", orphan_config)
        add_file(archive, "base/layer.tar", base_layer)
        add_file(archive, "orphan/layer.tar", orphan_layer)

    print(json.dumps({
        "base_image_id": base_image,
        "orphan_image_id": orphan_image,
        "base_chain_id": base_diff,
        "orphan_chain_id": digest(f"{base_diff} {orphan_diff}".encode()),
        "base_tag": base_tag,
        "orphan_tag": orphan_tag,
    }, sort_keys=True))


if __name__ == "__main__":
    main()
