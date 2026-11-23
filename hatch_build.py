"""Hatchling custom build hook compiling motoml's Mojo CPython extension (`_motoml.so`)."""

import shutil
import subprocess
import sys
import tempfile
from importlib.metadata import PackageNotFoundError, distribution
from pathlib import Path
from typing import override

from hatchling.builders.config import BuilderConfig
from hatchling.builders.hooks.plugin.interface import BuildHookInterface
from packaging.tags import sys_tags


def _detect_platform_tag() -> str:
    """Detect the target wheel platform tag from Modular wheel metadata or active host."""
    for dist_name in ("mojo-compiler", "mojo", "max-core"):
        try:
            wheel_text = distribution(dist_name).read_text("WHEEL")
        except PackageNotFoundError:
            continue
        if wheel_text is None:
            continue
        platform_tags = {
            line.partition(":")[2].strip().split("-", maxsplit=2)[2]
            for line in wheel_text.splitlines()
            if line.startswith("Tag:")
        }
        if len(platform_tags) == 1 and "any" not in platform_tags:
            return next(iter(platform_tags))

    # Fallback for conda/pixi environments where mojo-compiler is installed as a conda package
    host_tag = next(
        (
            tag.platform
            for tag in sys_tags()
            if tag.interpreter.startswith("cp")
            and tag.abi.startswith("cp")
            and tag.platform != "any"
        ),
        None,
    )
    if host_tag is None:
        msg = "Could not determine platform wheel tag"
        raise RuntimeError(msg)
    return host_tag


def _has_max_gpu_support() -> bool:
    """Return True if MAX GPU + layout Mojo libraries are installed in the build environment."""
    for dist_name in ("max-mojo-libs", "max-core", "max"):
        try:
            distribution(dist_name)
        except PackageNotFoundError:
            continue
        else:
            return True

    mojo_bin = shutil.which("mojo")
    if mojo_bin is not None:
        lib_mojo = Path(mojo_bin).resolve().parent.parent / "lib" / "mojo"
        if (lib_mojo / "max.mojoc").is_file() and (
            lib_mojo / "layout.mojoc"
        ).is_file():
            return True
    return False


class CustomBuildHook(BuildHookInterface[BuilderConfig]):
    @override
    def initialize(self, version: str, build_data: dict[str, object]) -> None:
        if self.target_name == "sdist":
            return

        platform_tag = _detect_platform_tag()

        python_tag = next(
            (
                tag
                for tag in sys_tags()
                if tag.interpreter.startswith("cp") and tag.abi.startswith("cp")
            ),
            None,
        )
        if python_tag is None:
            msg = "Could not determine the active CPython wheel tag"
            raise RuntimeError(msg)

        build_data["tag"] = (
            f"{python_tag.interpreter}-{python_tag.abi}-{platform_tag}"
        )
        build_data["pure_python"] = False

        project_root = Path(self.root)
        src_dir = project_root / "src"
        gpu_dir = project_root / "gpu"
        interop_dir = project_root / "python" / "interop"
        cpu_entry = interop_dir / "cpu_entry.mojo"
        gpu_entry = interop_dir / "gpu_entry.mojo"

        if not src_dir.is_dir():
            msg = f"Mojo source directory not found: {src_dir}"
            raise FileNotFoundError(msg)
        if not cpu_entry.is_file():
            msg = f"Mojo Python interop entrypoint not found: {cpu_entry}"
            raise FileNotFoundError(msg)

        use_gpu = (
            _has_max_gpu_support()
            and gpu_dir.is_dir()
            and gpu_entry.is_file()
        )

        output = project_root / "python" / "motoml" / "_motoml.so"
        output.parent.mkdir(parents=True, exist_ok=True)

        runtime_rpath = (
            "@loader_path/../modular/lib"
            if sys.platform == "darwin"
            else "$ORIGIN/../modular/lib"
        )

        with tempfile.TemporaryDirectory(prefix="motoml_build_") as tmp:
            tmp_path = Path(tmp)
            motoml_mojoc = tmp_path / "motoml.mojoc"
            subprocess.run(
                ["mojo", "precompile", str(src_dir), "-o", str(motoml_mojoc)],
                cwd=project_root,
                check=True,
            )

            entry = cpu_entry
            if use_gpu:
                gpu_mojoc = tmp_path / "motoml_gpu.mojoc"
                subprocess.run(
                    [
                        "mojo",
                        "precompile",
                        str(gpu_dir),
                        "-I",
                        str(tmp_path),
                        "-o",
                        str(gpu_mojoc),
                    ],
                    cwd=project_root,
                    check=True,
                )
                entry = gpu_entry

            cmd = [
                "mojo",
                "build",
                "-I",
                str(tmp_path),
                "-I",
                str(project_root / "python"),
                str(entry),
                "--emit",
                "shared-lib",
                "-o",
                str(output),
                "-Xlinker",
                "-rpath",
                "-Xlinker",
                runtime_rpath,
            ]
            subprocess.run(cmd, cwd=project_root, check=True)

        force_include = build_data.setdefault("force_include", {})
        if isinstance(force_include, dict):
            force_include[str(output)] = "motoml/_motoml.so"
