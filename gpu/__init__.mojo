"""GPU-accelerated TOML 1.1 parsing companion package (`motoml_gpu`).

Provides `GpuTomlParser` and convenience entry points built on `max.gpu` while keeping
core `motoml` 100% pure-Mojo (`mojo = "1.3.*"`) with zero CPU code modifications.
"""

from .parser import (
    DEFAULT_MIN_GPU_BYTES,
    GpuTomlParser,
    parse_toml_gpu,
    toml_to_tagged_json_gpu,
)
