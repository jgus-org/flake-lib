from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
from pathlib import Path


def verify_file(directory: Path, item: dict[str, object]) -> None:
    relative_path = item["path"]
    expected_size = item["bytes"]
    if not isinstance(relative_path, str) or not isinstance(expected_size, int):
        raise SystemExit("Manifest file entry has an invalid path or size")
    path = directory / relative_path
    if not path.is_file() or path.stat().st_size != expected_size:
        raise SystemExit(f"Missing file or wrong size: {relative_path}")
    sha256 = item.get("sha256")
    git_blob = item.get("git_blob")
    if isinstance(sha256, str):
        digest = hashlib.sha256()
        expected_digest = sha256
    elif isinstance(git_blob, str):
        digest = hashlib.sha1()
        digest.update(f"blob {expected_size}\0".encode())
        expected_digest = git_blob
    else:
        raise SystemExit(f"Manifest file entry has no checksum: {relative_path}")
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected_digest:
        raise SystemExit(f"Checksum mismatch: {relative_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("stamp_name")
    parser.add_argument("action", choices=("download", "verify", "check"))
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()

    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    if not isinstance(manifest, dict):
        raise SystemExit("Manifest must be a JSON object")
    files = manifest.get("files")
    revision = manifest.get("revision")
    repository = manifest.get("repo")
    total_bytes = manifest.get("total_bytes")
    if not isinstance(files, list) or not isinstance(revision, str) or not isinstance(repository, str) or not isinstance(total_bytes, int):
        raise SystemExit("Manifest is missing required model metadata")

    args.directory.mkdir(parents=True, exist_ok=True)
    stamp = args.directory / args.stamp_name
    expected = {
        "revision": revision,
        "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
    }

    with (args.directory.parent / f".{args.directory.name}.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action != "check":
            stamp.unlink(missing_ok=True)
        if args.action == "download":
            from huggingface_hub import snapshot_download

            snapshot_download(
                repo_id=repository,
                revision=revision,
                local_dir=args.directory,
                allow_patterns=[item["path"] for item in files],
                token=False,
                max_workers=4,
            )
        if args.action == "check":
            if not stamp.exists() or json.loads(stamp.read_text()) != expected:
                raise SystemExit("Model has not passed verification with this manifest")
            for item in files:
                relative_path = item.get("path") if isinstance(item, dict) else None
                expected_size = item.get("bytes") if isinstance(item, dict) else None
                path = args.directory / relative_path if isinstance(relative_path, str) else None
                if path is None or not isinstance(expected_size, int) or not path.is_file() or path.stat().st_size != expected_size:
                    raise SystemExit(f"Missing file or wrong size: {relative_path}")
        else:
            for item in files:
                if not isinstance(item, dict):
                    raise SystemExit("Manifest has an invalid file entry")
                verify_file(args.directory, item)
            temporary = stamp.with_suffix(".tmp")
            temporary.write_text(json.dumps(expected, indent=2) + "\n")
            temporary.replace(stamp)

    print(f"Model {revision}: {len(files)} files, {total_bytes} bytes; {args.action} passed")


if __name__ == "__main__":
    main()
