"""flake-lib artifact hook: resolve a pinned python wheel closure per declared environment, current plus readiness."""

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
from urllib.request import Request, urlopen

from packaging.utils import canonicalize_name, parse_wheel_filename


def load_deps_core():
    spec = importlib.util.spec_from_file_location("deps_core", os.environ["DEPS_CORE"])
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


deps_core = load_deps_core()


def run(*args: str, cwd: Path | None = None) -> None:
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
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
    if not only:
        return requirements
    wanted = {canonicalize_name(name) for name in only}
    selected = [requirement for requirement in requirements if canonicalize_name(requirement_name(requirement)) in wanted]
    missing = wanted - {canonicalize_name(requirement_name(requirement)) for requirement in selected}
    if missing:
        raise ValueError(f"wheelhouse source filter 'only' matched nothing for: {', '.join(sorted(missing))}")
    return selected


def requirement_name(requirement: str) -> str:
    return re.split("[^A-Za-z0-9._-]", requirement.strip(), maxsplit=1)[0]


def wheel_url(index_url: str, name: str, filename: str, digest: str) -> str:
    request = Request(
        f"{index_url.rstrip('/')}/{canonicalize_name(name)}/",
        headers={"Accept": "application/vnd.pypi.simple.v1+json"},
    )
    with urlopen(request) as response:
        files = json.load(response)["files"]
    for item in files:
        if item["filename"] == filename and item.get("hashes", {}).get("sha256") == digest:
            return item["url"]
    raise RuntimeError(f"the index did not report {filename} with {digest}")


def blocked_reason(error: subprocess.CalledProcessError) -> str:
    output = (error.stderr or "") + (error.stdout or "")
    lines = [line for line in output.splitlines() if line.strip()]
    error_lines = [line for line in lines if "error" in line.lower()]
    return (error_lines[-1] if error_lines else lines[-1] if lines else f"exit {error.returncode}")[:240]


def resolve_environment(environment: dict[str, Any], work: Path, requirements_in: Path, index_url: str) -> dict[str, Any]:
    env_work = work / f"env-{environment['python']}"
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
    )

    wheelhouse = env_work / "wheelhouse"
    wheelhouse.mkdir()
    platform_args = [tag for platform in environment["pipPlatforms"] for tag in ("--platform", platform)]
    run(
        "pip", "download",
        "--require-hashes",
        "--only-binary", ":all:",
        "--dest", str(wheelhouse),
        *platform_args,
        "--python-version", environment["pipPythonVersion"],
        "--implementation", "cp",
        "--abi", environment["pipAbi"],
        "--index-url", index_url,
        "--requirement", str(requirements_lock),
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


def main() -> None:
    flake_root = Path(os.environ["FLAKE_ROOT"])
    revision = os.environ["NEW_REV"]
    spec = json.loads(os.environ["WHEELHOUSE_SPEC"])
    index_url = os.environ["INDEX_URL"]
    owner = os.environ["GH_OWNER"]
    repo = os.environ["GH_REPO"]
    environments = spec["environments"]
    current = environments[0]
    readiness = [environment for environment in environments if environment["readiness"]]

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

        current_python = current["python"]
        current_artifacts = resolve_environment(current, work, requirements_in, index_url)
        shutil.copy2(requirements_in, flake_root / "requirements.in")
        shutil.copy2(current_artifacts["requirements_lock"], flake_root / f"requirements-{current_python}.lock")
        shutil.copy2(current_artifacts["wheel_manifest"], flake_root / f"wheels-{current_python}.json")

        statuses = {}
        for environment in readiness:
            python = environment["python"]
            stale = [flake_root / f"requirements-{python}.lock", flake_root / f"wheels-{python}.json"]
            try:
                artifacts = resolve_environment(environment, work, requirements_in, index_url)
            except subprocess.CalledProcessError as error:
                for path in stale:
                    path.unlink(missing_ok=True)
                statuses[python] = {"status": "blocked", "reason": blocked_reason(error)}
                print(f"readiness {python}: blocked — {statuses[python]['reason']}", file=sys.stderr)
                continue
            shutil.copy2(artifacts["requirements_lock"], flake_root / f"requirements-{python}.lock")
            shutil.copy2(artifacts["wheel_manifest"], flake_root / f"wheels-{python}.json")
            statuses[python] = {"status": "ok"}
            print(f"readiness {python}: ok", file=sys.stderr)

        if readiness:
            (flake_root / "python-readiness.json").write_text(json.dumps(statuses, indent=2, sort_keys=True) + "\n")

        print(f"pythonEnvironment={current['python']}")
        print(f"requirementsHash={sha256(current_artifacts['requirements_lock'])}")
        print(f"wheelManifestHash={sha256(current_artifacts['wheel_manifest'])}")


if __name__ == "__main__":
    main()
