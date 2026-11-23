"""Comprehensive tests for `toml_attr` annotations, extended containers/enums/unions,
cold-path `line:col` + path diagnostics, and `to_toml` / `write_toml` serialization."""

from std.collections import Array, Dict, List, Optional, Set
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)
from std.utils.numerics import inf, isinf, isnan, nan

from motoml import (
    CaseStyle,
    Date,
    DateTime,
    Mode,
    Offset,
    OneOf,
    Time,
    parse_toml,
    to_toml,
    toml_attr,
    try_parse_toml,
    try_to_toml,
    write_toml,
)


# --- 1. Case styles, rename, alias, default, default_init, skip, deny_unknown_fields ---


@__annotation(toml_attr.kebab_case, toml_attr.deny_unknown_fields)
@fieldwise_init
struct BuildSystemConfig(Equatable, Movable):
    var build_backend: String

    @__annotation(toml_attr.default(4), toml_attr.alias("parallel_jobs"))
    var max_jobs: UInt16

    @__annotation(toml_attr.rename("opt_level"), toml_attr.default(Int8(2)))
    var optimization_level: Int8

    @__annotation(toml_attr.default("release"))
    var profile_name: String

    @__annotation(toml_attr.default(0.75))
    var cache_ratio: Float32

    @__annotation(toml_attr.skip, toml_attr.default(999))
    var internal_runtime_id: Int

    @__annotation(toml_attr.skip)
    var transient_notes: List[String]

    @__annotation(toml_attr.default_init)
    var extra_flags: List[String]


@__annotation(toml_attr.rename_all(.camel))
@fieldwise_init
struct CamelStruct(Equatable, Movable):
    var first_name: String
    var max_retry_count: Int


@__annotation(toml_attr.pascal_case)
@fieldwise_init
struct PascalStruct(Equatable, Movable):
    var service_name: String
    var http_port: Int


@__annotation(toml_attr.screaming_snake_case)
@fieldwise_init
struct EnvConfig(Equatable, Movable):
    var api_token: String
    var log_level: Int


def test_annotations_rename_default_alias_skip_strict() raises:
    var src = """
    build-backend = "pixi-build-mojo"
    parallel_jobs = 16
    internal-runtime-id = 12345
    """
    # Wait: `internal-runtime-id` in TOML when `internal_runtime_id` is `skip`ped
    # should be treated as an UNKNOWN field by `deny_unknown_fields`!
    with assert_raises():
        _ = parse_toml(src).take[BuildSystemConfig]()

    var valid_src = """
    build-backend = "pixi-build-mojo"
    parallel_jobs = 16
    """
    var cfg = parse_toml(valid_src).take[BuildSystemConfig]()
    assert_equal(cfg.build_backend, "pixi-build-mojo")
    assert_equal(Int(cfg.max_jobs), 16)
    assert_equal(Int(cfg.optimization_level), 2)
    assert_equal(cfg.profile_name, "release")
    assert_equal(Float64(cfg.cache_ratio), 0.75)
    assert_equal(cfg.internal_runtime_id, 999)
    assert_equal(len(cfg.transient_notes), 0)
    assert_equal(len(cfg.extra_flags), 0)

    # Also test Eager and Trusted modes + explicit primary overriding default
    var full_src = """
    build-backend = "uv_build"
    max-jobs = 8
    opt_level = 3
    profile-name = "bench"
    cache-ratio = 0.5
    extra-flags = ["-O3", "-march=native"]
    """
    var ecfg = parse_toml[Mode.Eager](full_src).take[BuildSystemConfig]()
    assert_equal(ecfg.build_backend, "uv_build")
    assert_equal(Int(ecfg.max_jobs), 8)
    assert_equal(Int(ecfg.optimization_level), 3)
    assert_equal(ecfg.profile_name, "bench")
    assert_equal(ecfg.extra_flags[0], "-O3")
    assert_equal(ecfg.internal_runtime_id, 999)

    # Unknown field rejected with clear message
    var bad_unknown = 'build-backend = "uv"\ntypo-key = true\n'
    try:
        _ = parse_toml(bad_unknown).take[BuildSystemConfig]()
        assert_true(False, "expected unknown field error")
    except e:
        var msg = String(e)
        assert_true("Unknown field 'typo-key'" in msg)
        assert_true("2:1" in msg)

    # Duplicate key in Trusted mode also caught by deny_unknown_fields O(1) counter!
    var dup_trusted = 'build-backend = "a"\nbuild-backend = "b"\n'
    with assert_raises():
        _ = parse_toml[Mode.Trusted](dup_trusted).take[BuildSystemConfig]()

    # Camel, Pascal, ScreamingSnake case styles
    var camel = parse_toml('firstName = "Ada"\nmaxRetryCount = 5\n').take[
        CamelStruct
    ]()
    assert_equal(camel.first_name, "Ada")
    assert_equal(camel.max_retry_count, 5)

    var pascal = parse_toml('ServiceName = "auth"\nHttpPort = 443\n').take[
        PascalStruct
    ]()
    assert_equal(pascal.service_name, "auth")
    assert_equal(pascal.http_port, 443)

    var env = parse_toml('API_TOKEN = "xyz"\nLOG_LEVEL = 2\n').take[EnvConfig]()
    assert_equal(env.api_token, "xyz")
    assert_equal(env.log_level, 2)


# --- 2. Flatten (nested struct + catch-all Dict) ---


@__annotation(toml_attr.kebab_case)
@fieldwise_init
struct PackageMeta(Equatable, Movable):
    var pkg_name: String

    @__annotation(toml_attr.default("0.1.0"))
    var pkg_version: String


@__annotation(toml_attr.deny_unknown_fields)
@fieldwise_init
struct FlattenedStrictManifest(Equatable, Movable):
    var edition: Int

    @__annotation(toml_attr.flatten)
    var meta: PackageMeta


@fieldwise_init
struct FlattenedExtraManifest(Movable):
    var name: String

    @__annotation(toml_attr.flatten)
    var meta: PackageMeta

    @__annotation(toml_attr.flatten)
    var extra: Dict[String, Int]


def test_flatten_struct_and_dict() raises:
    var src1 = 'edition = 2026\npkg-name = "motoml"\n'
    var m1 = parse_toml(src1).take[FlattenedStrictManifest]()
    assert_equal(m1.edition, 2026)
    assert_equal(m1.meta.pkg_name, "motoml")
    assert_equal(m1.meta.pkg_version, "0.1.0")

    # Unknown key still rejected when flattening nested struct under deny_unknown_fields!
    with assert_raises():
        _ = parse_toml('edition = 2026\npkg-name = "motoml"\nbogus = 1\n').take[
            FlattenedStrictManifest
        ]()

    # Catch-all flattened Dict captures only unclaimed keys
    var src2 = """
    name = "workspace"
    pkg-name = "core"
    pkg-version = "1.3.0"
    custom_a = 10
    custom_b = 20
    """
    var m2 = parse_toml(src2).take[FlattenedExtraManifest]()
    assert_equal(m2.name, "workspace")
    assert_equal(m2.meta.pkg_name, "core")
    assert_equal(m2.meta.pkg_version, "1.3.0")
    assert_equal(len(m2.extra), 2)
    assert_equal(m2.extra["custom_a"], 10)
    assert_equal(m2.extra["custom_b"], 20)
    assert_false("name" in m2.extra)
    assert_false("pkg-name" in m2.extra)

    # Round-trip flattened extra manifest through to_toml!
    var dumped = to_toml(m2)
    var m2_rt = parse_toml(dumped).take[FlattenedExtraManifest]()
    assert_equal(m2_rt.name, "workspace")
    assert_equal(m2_rt.meta.pkg_name, "core")
    assert_equal(m2_rt.extra["custom_a"], 10)
    assert_equal(m2_rt.extra["custom_b"], 20)


# --- 3. Fieldless __enum & Rich __union (untagged, external, internal, adjacent) ---


@__annotation(toml_attr.kebab_case)
__enum LogLevel(Copyable, Equatable, Hashable, Writable):
    case trace_all
    case debug
    case info
    case warn_only


@__annotation(toml_attr.deny_unknown_fields)
@fieldwise_init
struct TcpBackend(Copyable, Equatable, Movable, Writable):
    var host: String
    var port: UInt16


@fieldwise_init
struct UnixBackend(Copyable, Equatable, Movable, Writable):
    var path: String


@__annotation(toml_attr.tag("type"), toml_attr.kebab_case)
__union InternalBackend(Copyable, Equatable, Movable, Writable):
    case disabled()
    case tcp_node(TcpBackend)
    case unix_socket(UnixBackend)


@__annotation(
    toml_attr.tag("kind"), toml_attr.content("data"), toml_attr.snake_case
)
__union AdjacentEvent(Copyable, Equatable, Movable, Writable):
    case ping()
    case message(String)
    case coords(Int, Int, String)


__union FlexUnion(Copyable, Equatable, Movable, Writable):
    case off()
    case port(Int)
    case host_port(String, UInt16)
    case unix(UnixBackend)


def test_enums_and_rich_unions() raises:
    # Fieldless __enum (plain, escaped, kebab-case, invalid)
    var edoc = parse_toml(
        'l1 = "trace-all"\nl2 = "\\u0069nfo"\nl3 = "warn-only"\n'
    )
    assert_equal(edoc["l1"].take[LogLevel](), LogLevel.trace_all)
    assert_equal(edoc["l2"].take[LogLevel](), LogLevel.info)
    assert_equal(edoc["l3"].take[LogLevel](), LogLevel.warn_only)
    with assert_raises():
        _ = parse_toml('l = "unknown"\n')["l"].take[LogLevel]()

    # Internally tagged union (including deny_unknown_fields on TcpBackend!)
    var ib1 = parse_toml(
        'type = "tcp-node"\nhost = "10.0.0.5"\nport = 8080\n'
    ).take[InternalBackend]()
    assert_equal(
        ib1,
        InternalBackend.tcp_node(TcpBackend(host="10.0.0.5", port=8080)),
    )
    var ib2 = parse_toml('type = "disabled"\n').take[InternalBackend]()
    assert_equal(ib2, InternalBackend.disabled())

    # Extra unknown field in TcpBackend inside internally tagged union must fail!
    with assert_raises():
        _ = parse_toml(
            'type = "tcp-node"\nhost = "10.0.0.5"\nport = 8080\nextra = 1\n'
        ).take[InternalBackend]()

    # Adjacently tagged union (unit, scalar, and multi-payload tuple!)
    var ae1 = parse_toml('kind = "ping"\n').take[AdjacentEvent]()
    assert_equal(ae1, AdjacentEvent.ping())
    var ae2 = parse_toml('kind = "message"\ndata = "hello"\n').take[
        AdjacentEvent
    ]()
    assert_equal(ae2, AdjacentEvent.message("hello"))
    var ae3 = parse_toml('kind = "coords"\ndata = [12, -4, "zone"]\n').take[
        AdjacentEvent
    ]()
    assert_equal(ae3, AdjacentEvent.coords(12, -4, "zone"))

    # Default union: unit string, untagged scalar, untagged tuple array, and external table
    var fu_doc = parse_toml(
        """
        u0 = "off"
        u1 = 9090
        u2 = ["127.0.0.1", 443]
        u3 = { host_port = ["0.0.0.0", 8443] }
        u4 = { unix = { path = "/tmp/s.sock" } }
        """
    )
    assert_equal(fu_doc["u0"].take[FlexUnion](), FlexUnion.off())
    assert_equal(fu_doc["u1"].take[FlexUnion](), FlexUnion.port(9090))
    assert_equal(
        fu_doc["u2"].take[FlexUnion](), FlexUnion.host_port("127.0.0.1", 443)
    )
    assert_equal(
        fu_doc["u3"].take[FlexUnion](), FlexUnion.host_port("0.0.0.0", 8443)
    )
    assert_equal(
        fu_doc["u4"].take[FlexUnion](),
        FlexUnion.unix(UnixBackend(path="/tmp/s.sock")),
    )

    # Root union round-trip through to_toml!
    var root_ib_toml = to_toml(ib1)
    assert_equal(parse_toml(root_ib_toml).take[InternalBackend](), ib1)
    var root_ae_toml = to_toml(ae3)
    assert_equal(parse_toml(root_ae_toml).take[AdjacentEvent](), ae3)


# --- 4. Tuple, Array, Set, Dict (String, StringSpan, Enum keys), & Partial Cleanup ---


struct ContainersConfig(Movable):
    var fixed_ports: Array[UInt16, 3]
    var names_arr: Array[String, 2]
    var header_tuple: Tuple[String, Int, Bool]
    var empty_tuple: Tuple[]
    var tags: Set[String]
    var env: Dict[String, String]
    var level_quotas: Dict[LogLevel, Int]


struct ZeroCopyDictConfig[origin: ImmOrigin](Movable):
    var labels: Dict[StringSpan[Self.origin], Int]


def test_containers_tuple_array_set_dict() raises:
    var src = """
    fixed_ports = [80, 443, 8080]
    names_arr = ["alpha", "beta"]
    header_tuple = ["X-Rate-Limit", 100, true]
    empty_tuple = []
    tags = ["fast", "safe", "fast", "zero-copy"]

    [env]
    RUST_LOG = "info"
     "PATH.EXT" = "/usr/local/bin"

    [level_quotas]
    trace-all = 10
    info = 1000
    warn-only = 5000
    """
    var doc = parse_toml(src)
    var c = doc.take[ContainersConfig]()
    assert_equal(Int(c.fixed_ports[0]), 80)
    assert_equal(Int(c.fixed_ports[2]), 8080)
    assert_equal(c.names_arr[0], "alpha")
    assert_equal(c.names_arr[1], "beta")
    assert_equal(c.header_tuple[0], "X-Rate-Limit")
    assert_equal(c.header_tuple[1], 100)
    assert_equal(c.header_tuple[2], True)
    assert_equal(len(c.tags), 3)
    assert_true("fast" in c.tags)
    assert_true("zero-copy" in c.tags)
    assert_equal(c.env["RUST_LOG"], "info")
    assert_equal(c.env["PATH.EXT"], "/usr/local/bin")
    assert_equal(c.level_quotas[LogLevel.trace_all], 10)
    assert_equal(c.level_quotas[LogLevel.info], 1000)
    assert_equal(c.level_quotas[LogLevel.warn_only], 5000)

    # Zero-copy StringSpan Dict in Strict & Eager
    var zsrc = "a = 1\nb = 2\n"
    var zdoc = parse_toml(zsrc)
    var zmap = zdoc.take[Dict[StringSpan[ImmOrigin(origin_of(zdoc))], Int]]()
    assert_equal(len(zmap), 2)
    for entry in zmap.items():
        if entry.key == "a":
            assert_equal(entry.value, 1)
        else:
            assert_equal(entry.key, "b")
            assert_equal(entry.value, 2)

    var edoc = parse_toml[Mode.Eager]('"a\\nb" = 42\n')
    var emap = edoc.take[Dict[StringSpan[ImmOrigin(origin_of(edoc))], Int]]()
    assert_equal(len(emap), 1)
    for entry in emap.items():
        assert_equal(entry.key, "a\nb")
        assert_equal(entry.value, 42)

    # Partial destruction safety when later element of Tuple or Array fails
    var bad_tup_doc = parse_toml(
        't = ["allocated heap string", "not_an_int"]\n'
    )
    with assert_raises():
        _ = bad_tup_doc["t"].take[Tuple[String, Int]]()

    var bad_arr_doc = parse_toml('a = ["heap one", "heap two", 999]\n')
    with assert_raises():
        _ = bad_arr_doc["a"].take[Array[String, 3]]()

    # Wrong length rejected for Tuple and Array
    with assert_raises():
        _ = parse_toml("a = [1, 2]\n")["a"].take[Array[Int, 3]]()
    with assert_raises():
        _ = parse_toml("t = [1, 2, 3]\n")["t"].take[Tuple[Int, Int]]()


# --- 5. Hierarchical Path + `line:col` Diagnostics ---


struct LeafTarget(Movable):
    var host: String
    var port: UInt16


struct ServiceNode(Movable):
    var routes: List[LeafTarget]
    var upstreams: Dict[String, LeafTarget]
    var pair: Tuple[String, UInt8]


def test_path_and_line_col_diagnostics() raises:
    var bad_route_src = (
        'pair = ["ok", 1]\n'
        "[upstreams]\n"
        "[[routes]]\n"
        'host = "a"\n'
        "port = 80\n"
        "[[routes]]\n"
        'host = "b"\n'
        "port = 99999\n"
    )
    try:
        _ = parse_toml(bad_route_src).take[ServiceNode]()
        assert_true(False, "expected range error")
    except e:
        var msg = String(e)
        assert_true("routes[1].port" in msg)
        assert_true("(8:8)" in msg)
        assert_true("UInt16" in msg)

    var bad_dict_src = (
        'pair = ["ok", 1]\n'
        "routes = []\n"
        "[upstreams.edge]\n"
        'host = "1.1.1.1"\n'
        'port = "wrong_kind"\n'
    )
    try:
        _ = parse_toml(bad_dict_src).take[ServiceNode]()
        assert_true(False, "expected kind error")
    except e:
        var msg = String(e)
        assert_true("upstreams.edge.port" in msg)
        assert_true("(5:8)" in msg)

    var bad_tuple_src = 'pair = ["ok", 300]\nroutes = []\n[upstreams]\n'
    try:
        _ = parse_toml(bad_tuple_src).take[ServiceNode]()
        assert_true(False, "expected tuple UInt8 range error")
    except e:
        var msg = String(e)
        assert_true("pair[1]" in msg)
        assert_true("(1:15)" in msg)


# --- 6. Full `to_toml` / `write_toml` Serialization & Round-Tripping ---


@fieldwise_init
struct EmptyMarker(Equatable, Movable):
    pass


@__annotation(toml_attr.kebab_case)
@fieldwise_init
struct FullRoundTripConfig(Movable):
    var app_title: String
    var special_chars: String
    var max_workers: Int
    var small_delta: Int8
    var listen_port: UInt16
    var threshold: Float64
    var nan_val: Float64
    var pos_inf: Float64
    var neg_inf: Float64
    var enabled: Bool
    var release_date: Date
    var cutoff_time: Time
    var deployed_at: DateTime
    var log_level: LogLevel
    var present_opt: Optional[String]
    var absent_opt: Optional[Int]

    @__annotation(toml_attr.skip_if_empty, toml_attr.default_init)
    var skipped_empty_list: List[Int]

    @__annotation(toml_attr.skip_if_empty, toml_attr.default_init)
    var kept_nonempty_list: List[Int]
    var empty_routes: List[TcpBackend]
    var active_routes: List[TcpBackend]
    var empty_sub: EmptyMarker
    var tuple_val: Tuple[String, Int, TcpBackend]
    var fixed_arr: Array[Int, 3]
    var listen_one_of: OneOf[Int, String]
    var backend: InternalBackend
    var event: AdjacentEvent
    var dotted_keys_map: Dict[String, Int]


def test_to_toml_and_full_roundtrip() raises:
    var dmap = Dict[String, Int]()
    dmap["normal_key"] = 1
    dmap["dotted.key"] = 2
    dmap[""] = 3
    dmap['quote"key\x7f'] = 4

    var original = FullRoundTripConfig(
        app_title="motoml-gateway",
        special_chars='line1\nline2\t"quoted"\\slash\x7f\x01🚀',
        max_workers=32,
        small_delta=Int8(-15),
        listen_port=UInt16(8443),
        threshold=42.0,
        nan_val=nan[DType.float64](),
        pos_inf=inf[DType.float64](),
        neg_inf=-inf[DType.float64](),
        enabled=True,
        release_date=Date(year=2026, month=11, day=22),
        cutoff_time=Time(hour=14, minute=5, second=9, nanosecond=125_000_000),
        deployed_at=DateTime(
            date=Date(year=2026, month=11, day=22),
            time=Time(hour=9, minute=30, second=0),
            offset=Offset(hour=5, minute=0, positive=False),
            is_local=False,
        ),
        log_level=LogLevel.warn_only,
        present_opt=Optional(String("present")),
        absent_opt=Optional[Int](None),
        skipped_empty_list=List[Int](),
        kept_nonempty_list=[10, 20],
        empty_routes=List[TcpBackend](),
        active_routes=[
            TcpBackend(host="10.0.0.1", port=8001),
            TcpBackend(host="10.0.0.2", port=8002),
        ],
        empty_sub=EmptyMarker(),
        tuple_val=("primary", 7, TcpBackend(host="127.0.0.1", port=9000)),
        fixed_arr=[4, 5, 6],
        listen_one_of=OneOf[Int, String](String("0.0.0.0:443")),
        backend=InternalBackend.tcp_node(
            TcpBackend(host="edge.internal", port=443)
        ),
        event=AdjacentEvent.coords(5, 9, "ok"),
        dotted_keys_map=dmap^,
    )

    var toml_out = to_toml(original)
    # `skipped-empty-list` and `absent-opt` must be omitted from output!
    assert_false("skipped-empty-list" in toml_out)
    assert_false("absent-opt" in toml_out)
    # `empty-routes = []` and `[empty-sub]` must be present so round-trip succeeds!
    assert_true("empty-routes = []" in toml_out)
    assert_true("[empty-sub]" in toml_out)
    # Control byte 0x7F must be escaped (`\u007f`) for Strict TOML 1.1 compliance!
    assert_true("\\u007f" in toml_out)

    # Verify streaming write_toml produces byte-for-byte identical output
    var streamed = String()
    write_toml(original, streamed)
    assert_equal(streamed, toml_out)

    # Round-trip in Mode.Strict AND Mode.Eager!
    var restored = parse_toml[Mode.Strict](toml_out).take[FullRoundTripConfig]()
    assert_equal(restored.app_title, "motoml-gateway")
    assert_equal(
        restored.special_chars, 'line1\nline2\t"quoted"\\slash\x7f\x01🚀'
    )
    assert_equal(restored.max_workers, 32)
    assert_equal(Int(restored.small_delta), -15)
    assert_equal(Int(restored.listen_port), 8443)
    assert_equal(restored.threshold, 42.0)
    assert_true(isnan(restored.nan_val))
    assert_true(isinf(restored.pos_inf) and restored.pos_inf > 0.0)
    assert_true(isinf(restored.neg_inf) and restored.neg_inf < 0.0)
    assert_true(restored.enabled)
    assert_equal(restored.release_date, Date(year=2026, month=11, day=22))
    assert_equal(
        restored.cutoff_time,
        Time(hour=14, minute=5, second=9, nanosecond=125_000_000),
    )
    assert_equal(restored.log_level, LogLevel.warn_only)
    assert_equal(restored.present_opt, Optional(String("present")))
    assert_false(Bool(restored.absent_opt))
    assert_equal(len(restored.skipped_empty_list), 0)
    assert_equal(restored.kept_nonempty_list, [10, 20])
    assert_equal(len(restored.empty_routes), 0)
    assert_equal(len(restored.active_routes), 2)
    assert_equal(restored.active_routes[1].host, "10.0.0.2")
    assert_equal(Int(restored.active_routes[1].port), 8002)
    assert_equal(restored.tuple_val[0], "primary")
    assert_equal(restored.tuple_val[1], 7)
    assert_equal(Int(restored.tuple_val[2].port), 9000)
    assert_equal(restored.fixed_arr[0], 4)
    assert_equal(restored.fixed_arr[2], 6)
    assert_equal(restored.listen_one_of[String], "0.0.0.0:443")
    assert_equal(
        restored.backend,
        InternalBackend.tcp_node(TcpBackend(host="edge.internal", port=443)),
    )
    assert_equal(restored.event, AdjacentEvent.coords(5, 9, "ok"))
    assert_equal(restored.dotted_keys_map["normal_key"], 1)
    assert_equal(restored.dotted_keys_map["dotted.key"], 2)
    assert_equal(restored.dotted_keys_map[""], 3)
    assert_equal(restored.dotted_keys_map['quote"key\x7f'], 4)

    var eager_restored = parse_toml[Mode.Eager](toml_out).take[
        FullRoundTripConfig
    ]()
    assert_equal(eager_restored.special_chars, restored.special_chars)
    assert_equal(
        eager_restored.dotted_keys_map['quote"key\x7f'],
        restored.dotted_keys_map['quote"key\x7f'],
    )

    # Root Dict[String, ...] serialization round-trip
    var root_dict = Dict[String, TcpBackend]()
    root_dict["alpha"] = TcpBackend(host="a.local", port=80)
    root_dict["beta.svc"] = TcpBackend(host="b.local", port=81)
    var root_dict_toml = to_toml(root_dict)
    var root_dict_rt = parse_toml(root_dict_toml).take[
        Dict[String, TcpBackend]
    ]()
    assert_equal(root_dict_rt["alpha"].host, "a.local")
    assert_equal(Int(root_dict_rt["beta.svc"].port), 81)


comptime _COMPTIME_SERDE_TOML: StaticString = """
build-backend = "pixi-build-mojo"
parallel_jobs = 12
"""


def _comptime_roundtrip_check() -> String:
    var doc = try_parse_toml[Mode.Eager](
        _COMPTIME_SERDE_TOML
    ).unsafe_take_value()
    var cfg = doc.try_take[BuildSystemConfig]().unsafe_take_value()
    return try_to_toml(cfg).unsafe_take_value()


def test_comptime_reflection_and_to_toml() raises:
    comptime DUMPED = _comptime_roundtrip_check()
    var rt_str = materialize[DUMPED]()
    var cfg = parse_toml(rt_str).take[BuildSystemConfig]()
    assert_equal(cfg.build_backend, "pixi-build-mojo")
    assert_equal(Int(cfg.max_jobs), 12)
    assert_equal(Int(cfg.optimization_level), 2)
    assert_equal(cfg.profile_name, "release")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
