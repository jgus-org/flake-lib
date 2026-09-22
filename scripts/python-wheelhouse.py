"""flake-lib artifact hook: resolve a pinned python wheel closure for every declared environment."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name, parse_wheel_filename


def load_deps_core():
    spec = importlib.util.spec_from_file_location("deps_core", os.environ["DEPS_CORE"])
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


deps_core = load_deps_core()


class ResolutionError(RuntimeError):
    pass


def run(*args: str, cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    result = subprocess.run(args, cwd=cwd, env=os.environ | env if env else None, capture_output=True, text=True)
    if result.returncode != 0:
        if result.stdout:
            print(result.stdout, end="", file=sys.stderr)
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, args, output=result.stdout, stderr=result.stderr)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checkout_source(work: Path, owner: str, repo: str, revision: str) -> Path:
    forge = "gitlab.com" if os.environ.get("SOURCE_TYPE") == "gitlab" else "github.com"
    source = work / "source"
    run("git", "clone", "--quiet", "--filter=blob:none", "--no-checkout",
        f"https://{forge}/{owner}/{repo}.git", str(source))
    run("git", "checkout", "--quiet", revision, cwd=source)
    return source


def source_requirements(source: dict[str, Any], flake_root: Path, checkout: Path | None) -> list[str]:
    kind = source["kind"]
    if kind == "source-pyproject":
        assert checkout is not None
        document = (checkout / "pyproject.toml").read_text()
        requirements = deps_core.pyproject_requirements(document, source.get("groups", []))
        if source.get("buildSystem", False):
            requirements.extend(tomllib.loads(document)["build-system"]["requires"])
        return filtered(source, requirements)
    if kind == "source-file":
        assert checkout is not None
        return filtered(source, deps_core.requirements_file_requirements((checkout / source["path"]).read_text()))
    if kind == "repo-file":
        return filtered(source, deps_core.requirements_file_requirements((flake_root / source["path"]).read_text()))
    raise ValueError(f"unknown wheelhouse source kind: {kind}")


def filtered(source: dict[str, Any], requirements: list[str]) -> list[str]:
    only = source.get("only")
    except_ = source.get("except")
    if only:
        wanted = {canonicalize_name(name) for name in only}
        selected = [requirement for requirement in requirements if canonicalize_name(requirement_name(requirement)) in wanted]
        missing = wanted - {canonicalize_name(requirement_name(requirement)) for requirement in selected}
        if missing:
            raise ValueError(f"wheelhouse source filter 'only' matched nothing for: {', '.join(sorted(missing))}")
        return selected
    if except_:
        excluded = {canonicalize_name(name) for name in except_}
        return [requirement for requirement in requirements if canonicalize_name(requirement_name(requirement)) not in excluded]
    return requirements


def requirement_name(requirement: str) -> str:
    return re.split("[^A-Za-z0-9._-]", requirement.strip(), maxsplit=1)[0]


def wheel_url(index_url: str, name: str, filename: str, digest: str) -> str:
    request = Request(
        f"{index_url.rstrip('/')}/{canonicalize_name(name)}/",
        headers={"Accept": "application/vnd.pypi.simple.v1+json"},
    )
    try:
        with urlopen(request) as response:
            document = json.load(response)
        files = document["files"]
        if not isinstance(files, list):
            raise TypeError("files is not a list")
    except (HTTPError, URLError, TimeoutError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise ResolutionError(f"the index response for {name} is unavailable or invalid: {error}") from error
    for item in files:
        try:
            if item["filename"] == filename and item.get("hashes", {}).get("sha256") == digest:
                url = item["url"]
                if not isinstance(url, str):
                    raise TypeError("url is not a string")
                return url
        except (AttributeError, KeyError, TypeError) as error:
            raise ResolutionError(f"the index response for {name} contains an invalid file entry: {error}") from error
    raise ResolutionError(f"the index did not report {filename} with {digest}")


def requirement_text(requirement: Requirement) -> str:
    extras = f"[{','.join(sorted(requirement.extras))}]" if requirement.extras else ""
    if requirement.url is not None:
        return f"{requirement.name}{extras} @ {requirement.url}"
    return f"{requirement.name}{extras}{requirement.specifier}"


def logical_requirement_lines(text: str) -> list[str]:
    entries = []
    current = ""
    for line in text.splitlines():
        stripped = line.rstrip()
        if stripped.endswith("\\"):
            current += stripped[:-1].rstrip() + " "
        else:
            entries.append(current + stripped)
            current = ""
    if current:
        raise ResolutionError("the resolved requirements file ends with a continuation")
    return entries


def target_requirements(requirements_lock: Path, marker_environment: dict[str, str]) -> str:
    selected = []
    for entry in logical_requirement_lines(requirements_lock.read_text()):
        stripped = entry.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = re.split(r"(\s+--hash=)", stripped, maxsplit=1)
        requirement_part = parts[0]
        hashes = " " + " ".join("".join(parts[1:]).split()) if len(parts) > 1 else ""
        requirement = Requirement(requirement_part)
        if requirement.marker is None or requirement.marker.evaluate(marker_environment):
            selected.append(requirement_text(requirement) + hashes)
    return "\n".join(selected) + "\n"


def resolve_environment(environment: dict[str, Any], work: Path, requirements_in: Path, index_url: str) -> dict[str, Any]:
    env_work = work / f"env-{environment['python']}-{environment['system']}"
    env_work.mkdir()
    shutil.copy2(requirements_in, env_work / "requirements.in")

    requirements_lock = env_work / "requirements.lock"
    run(
        "uv", "pip", "compile", "requirements.in",
        "--python-version", environment["uvPythonVersion"],
        "--python-platform", environment["uvPythonPlatform"],
        "--generate-hashes",
        "--index-url", index_url,
        "--output-file", requirements_lock.name,
        "--no-header",
        cwd=env_work,
        env=environment["uvEnvironment"],
    )

    requirements_target = env_work / "requirements.target"
    requirements_target.write_text(target_requirements(requirements_lock, environment["markerEnvironment"]))

    wheelhouse = env_work / "wheelhouse"
    wheelhouse.mkdir()
    platform_args = [tag for platform in environment["pipPlatforms"] for tag in ("--platform", platform)]
    run(
        "pip", "download",
        "--require-hashes",
        "--no-deps",
        "--only-binary", ":all:",
        "--dest", str(wheelhouse),
        *platform_args,
        "--python-version", environment["pipPythonVersion"],
        "--implementation", "cp",
        "--abi", environment["pipAbi"],
        "--index-url", index_url,
        "--requirement", str(requirements_target),
    )

    manifest = []
    for artifact in sorted(wheelhouse.glob("*.whl"), key=lambda path: path.name.lower()):
        name, version, _build, _tags = parse_wheel_filename(artifact.name)
        digest = sha256(artifact)
        manifest.append({
            "name": canonicalize_name(name),
            "version": str(version),
            "filename": artifact.name,
            "url": wheel_url(index_url, str(name), artifact.name, digest),
            "sha256": digest,
            "size": artifact.stat().st_size,
        })
    if not manifest:
        raise RuntimeError("pip download produced no wheels")

    wheel_manifest = env_work / "wheels.json"
    wheel_manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    return {
        "requirements_lock": requirements_lock,
        "wheel_manifest": wheel_manifest,
    }


def aggregate_hash(
    environments: list[dict[str, Any]],
    resolved: dict[tuple[str, str], dict[str, Any]],
    artifact: str,
) -> str:
    entries = [
        {
            "python": environment["python"],
            "system": environment["system"],
            "sha256": sha256(resolved[environment_key(environment)][artifact]),
        }
        for environment in environments
    ]
    encoded = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def environment_key(environment: dict[str, Any]) -> tuple[str, str]:
    return environment["python"], environment["system"]


def artifact_names(environment: dict[str, Any]) -> tuple[str, str]:
    stem = f"{environment['python']}-{environment['system']}"
    return f"requirements-{stem}.lock", f"wheels-{stem}.json"


def publish_artifacts(
    flake_root: Path,
    requirements_in: Path,
    environments: list[dict[str, Any]],
    resolved: dict[tuple[str, str], dict[str, Any]],
) -> None:
    artifacts = {
        "requirements.in": requirements_in,
        **{
            name: resolved[environment_key(environment)][artifact]
            for environment in environments
            for name, artifact in zip(artifact_names(environment), ("requirements_lock", "wheel_manifest"), strict=True)
        },
    }
    declared = set(artifacts)
    stale = [
        path
        for pattern in ("requirements-*.lock", "wheels-*.json")
        for path in flake_root.glob(pattern)
        if path.name not in declared
    ]
    with tempfile.TemporaryDirectory(prefix=".python-wheelhouse-", dir=flake_root) as raw_staging:
        staging = Path(raw_staging)
        backup = staging / "backup"
        backup.mkdir()
        targets = [
            *(flake_root / name for name in artifacts),
            *stale,
            flake_root / "python-readiness.json",
        ]
        previous = {path: backup / path.name if path.exists() else None for path in targets}
        for path, backup_path in previous.items():
            if backup_path is not None:
                shutil.copy2(path, backup_path)
        for name, source in artifacts.items():
            shutil.copy2(source, staging / name)
        try:
            for name in artifacts:
                (staging / name).replace(flake_root / name)
            for path in stale:
                path.unlink()
            (flake_root / "python-readiness.json").unlink(missing_ok=True)
        except OSError as publication_error:
            rollback_errors = []
            for path, backup_path in previous.items():
                try:
                    if backup_path is None:
                        path.unlink(missing_ok=True)
                    else:
                        shutil.copy2(backup_path, path)
                except OSError as rollback_error:
                    rollback_errors.append(rollback_error)
            if rollback_errors:
                raise publication_error from ExceptionGroup("wheelhouse artifact rollback failed", rollback_errors)
            raise


def main() -> None:
    flake_root = Path(os.environ["FLAKE_ROOT"])
    revision = os.environ["NEW_REV"]
    spec = json.loads(os.environ["WHEELHOUSE_SPEC"])
    index_url = spec["indexUrl"]
    owner = os.environ["GH_OWNER"]
    repo = os.environ["GH_REPO"]
    environments = spec["environments"]

    needs_checkout = any(source["kind"] != "repo-file" for source in spec["sources"])

    with tempfile.TemporaryDirectory(prefix="python-wheelhouse-") as raw_work:
        work = Path(raw_work)
        checkout = checkout_source(work, owner, repo, revision) if needs_checkout else None

        requirements = []
        for source in spec["sources"]:
            requirements.extend(source_requirements(source, flake_root, checkout))
        requirements.extend(spec.get("extraRequirements", []))
        deduplicated = list(dict.fromkeys(requirements))
        if not deduplicated:
            raise RuntimeError("the wheelhouse spec produced no requirements")

        header = "# Generated by flake-lib python-wheelhouse"
        if needs_checkout:
            header += f" from {owner}/{repo}@{revision}"
        requirements_in = work / "requirements.in"
        requirements_in.write_text(f"{header}\n" + "\n".join(deduplicated) + "\n")

        resolved = {
            environment_key(environment): resolve_environment(environment, work, requirements_in, index_url)
            for environment in environments
        }

        publish_artifacts(flake_root, requirements_in, environments, resolved)

        print(f"artifactFingerprint={spec['fingerprint']}")
        print(f"requirementsHash={aggregate_hash(environments, resolved, 'requirements_lock')}")
        print(f"wheelManifestHash={aggregate_hash(environments, resolved, 'wheel_manifest')}")


if __name__ == "__main__":
    main()
