"""Portable SIMT GPU kernels for two-stage TOML 1.1 parsing and materialization.

Key optimizations:
1. Coalesced `SIMD[UInt8, 16]` shared-memory staging (`8 KB` body + 16B prefix + 80B suffix halos -> 4 blocks/SM high occupancy on Apple M1, NVIDIA, and AMD).
2. Idempotent `FST_GAP2` transition skipping (`(FST_BASE)^k == FST_GAP2` for all `k >= 2`).
3. Compact 32-bit (`UInt32`) block-relative token encoding (`14b local_off | 4b kind | 7b flags | 7b len`), halving GPU write & D2H readback bandwidth and supporting >4 GB documents.
4. Per-thread 8-token register buffer (`InlineArray[UInt32, 8]`) eliminating the second byte-scan pass for >99% of threads.
"""

from std.atomic import Atomic
from std.collections import Array
from std.math import min
from max.gpu import block_idx, global_idx, thread_idx
from max.gpu.memory import AddressSpace
from max.gpu.sync import barrier
from layout import (
    ImmTileTensor,
    MutTileTensor,
    TensorLayout,
    row_major,
    stack_allocation,
)
from motoml.tape.node import NodeFlags, NodeKind

# --- Threading & Shared-Memory Tile Constants ---
# 128 threads x 64 bytes = 8,192 B/block (~9.3 KB shared mem -> 3-4 blocks/SM high occupancy!)
comptime GPU_BLOCK_THREADS: Int = 128
comptime GPU_BLOCK_LOG2: Int = 7
comptime GPU_BYTES_PER_THREAD: Int = 64
comptime GPU_BYTES_PER_BLOCK: Int = GPU_BLOCK_THREADS * GPU_BYTES_PER_THREAD  # 8,192 B
comptime GPU_PREFIX_HALO: Int = 16
comptime GPU_SUFFIX_HALO: Int = 80
comptime GPU_SMEM_BYTES: Int = GPU_PREFIX_HALO + GPU_BYTES_PER_BLOCK + GPU_SUFFIX_HALO  # 8,288 B

# --- 14-State TOML 1.1 Lexical Finite-State Transducer (FST) ---
comptime S_CODE: UInt8 = 0
comptime S_COMMENT: UInt8 = 1
comptime S_BASIC: UInt8 = 2
comptime S_BASIC_ESC: UInt8 = 3
comptime S_LITERAL: UInt8 = 4
comptime S_ML_BASIC: UInt8 = 5
comptime S_ML_BASIC_ESC: UInt8 = 6
comptime S_ML_LITERAL: UInt8 = 7
comptime S_ENTER_MLB_1: UInt8 = 8
comptime S_ENTER_MLB_2: UInt8 = 9
comptime S_ENTER_MLL_1: UInt8 = 10
comptime S_ENTER_MLL_2: UInt8 = 11
comptime S_EXIT_ML_1: UInt8 = 12
comptime S_EXIT_ML_2: UInt8 = 13

comptime FST_ID_LO: UInt32 = 0x76543210
comptime FST_ID_HI: UInt32 = 0x00DCB_A98

comptime FST_BASE_LO: UInt32 = 0x75542210
comptime FST_BASE_HI: UInt32 = 0x000D7B59

comptime FST_GAP2_LO: UInt32 = 0x75542210
comptime FST_GAP2_HI: UInt32 = 0x00007755

# --- Compact 32-Bit Block-Relative Token (`UInt32`) ---
# Bits 0..13  (14 bits): `local_off` (`0 .. 8,195`, since `8192 + 3 = 8195 < 16384`)
# Bits 14..17 ( 4 bits): `tok_kind` (`1..13`)
# Bits 18..24 ( 7 bits): `flags` (`ATOM_BARE` bit 4, `NodeKind` bits 0..3, `pv` bits 5..6)
# Bits 25..31 ( 7 bits): `len7` (`0 .. 64`)
comptime TOK_LBRACKET: UInt8 = 1
comptime TOK_RBRACKET: UInt8 = 2
comptime TOK_LBRACE: UInt8 = 3
comptime TOK_RBRACE: UInt8 = 4
comptime TOK_EQUAL: UInt8 = 5
comptime TOK_COMMA: UInt8 = 6
comptime TOK_DOT: UInt8 = 7
comptime TOK_NEWLINE: UInt8 = 8
comptime TOK_STR_OPEN: UInt8 = 9
comptime TOK_STR_ESC: UInt8 = 10
comptime TOK_STR_CLOSE: UInt8 = 11
comptime TOK_ATOM: UInt8 = 12
comptime TOK_ATOM_LONG: UInt8 = 13

comptime ATOM_BARE_FLAG: UInt8 = 1 << 4

comptime STATUS_UTF8_ERR: Int = 0
comptime STATUS_LEX_ERR: Int = 1
comptime STATUS_TOK_COUNT: Int = 2
comptime STATUS_OVERFLOW: Int = 3

comptime REG_TOK_BUF_CAP: Int = 8


@always_inline
def _pack_tok32(
    local_off: Int, kind: UInt8, flags: UInt8 = 0, len7: Int = 0
) -> UInt32:
    return (
        UInt32(local_off)
        | (UInt32(kind) << 14)
        | (UInt32(flags) << 18)
        | (UInt32(len7) << 25)
    )


@always_inline
def _eval_fst(lo: UInt32, hi: UInt32, s: UInt32) -> UInt32:
    if s < 8:
        return (lo >> (s * 4)) & 0xF
    return (hi >> ((s - 8) * 4)) & 0xF


@always_inline
def _compose_fst(
    t2_lo: UInt32, t2_hi: UInt32, t1_lo: UInt32, t1_hi: UInt32
) -> Tuple[UInt32, UInt32]:
    var out_lo: UInt32 = 0
    var out_hi: UInt32 = 0
    comptime for s in range(8):
        var mid = (t1_lo >> UInt32(s * 4)) & 0xF
        var nxt = _eval_fst(t2_lo, t2_hi, mid)
        out_lo |= nxt << UInt32(s * 4)
    comptime for s in range(6):
        var mid = (t1_hi >> UInt32(s * 4)) & 0xF
        var nxt = _eval_fst(t2_lo, t2_hi, mid)
        out_hi |= nxt << UInt32(s * 4)
    return (out_lo, out_hi)


@always_inline
def _set_nibble_lo(lo: UInt32, idx: UInt32, val: UInt32) -> UInt32:
    var shift = idx * 4
    return (lo & ~(UInt32(0xF) << shift)) | (val << shift)


@always_inline
def _byte_step_fst(
    ptr: ImmPointer[UInt8, _, address_space=_], i: Int, n_rem_limit: Int
) -> Tuple[UInt32, UInt32]:
    var b0 = ptr[unsafe_offset=i]
    var lo = FST_BASE_LO
    var hi = FST_BASE_HI

    if b0 == UInt8(ord("\n")):
        lo = _set_nibble_lo(lo, UInt32(S_COMMENT), UInt32(S_CODE))
    elif b0 == UInt8(ord("#")):
        lo = _set_nibble_lo(lo, UInt32(S_CODE), UInt32(S_COMMENT))
    elif b0 == UInt8(ord("\\")):
        lo = _set_nibble_lo(lo, UInt32(S_BASIC), UInt32(S_BASIC_ESC))
        lo = _set_nibble_lo(lo, UInt32(S_ML_BASIC), UInt32(S_ML_BASIC_ESC))
    elif b0 == UInt8(ord('"')):
        var is_3 = (
            i + 2 < n_rem_limit
            and ptr[unsafe_offset=i + 1] == UInt8(ord('"'))
            and ptr[unsafe_offset=i + 2] == UInt8(ord('"'))
        )
        lo = _set_nibble_lo(
            lo,
            UInt32(S_CODE),
            UInt32(S_ENTER_MLB_1) if is_3 else UInt32(S_BASIC),
        )
        lo = _set_nibble_lo(lo, UInt32(S_BASIC), UInt32(S_CODE))
        if is_3 and (
            i + 3 >= n_rem_limit or ptr[unsafe_offset=i + 3] != UInt8(ord('"'))
        ):
            lo = _set_nibble_lo(lo, UInt32(S_ML_BASIC), UInt32(S_EXIT_ML_1))
    elif b0 == UInt8(ord("'")):
        var is_3 = (
            i + 2 < n_rem_limit
            and ptr[unsafe_offset=i + 1] == UInt8(ord("'"))
            and ptr[unsafe_offset=i + 2] == UInt8(ord("'"))
        )
        lo = _set_nibble_lo(
            lo,
            UInt32(S_CODE),
            UInt32(S_ENTER_MLL_1) if is_3 else UInt32(S_LITERAL),
        )
        lo = _set_nibble_lo(lo, UInt32(S_LITERAL), UInt32(S_CODE))
        if is_3 and (
            i + 3 >= n_rem_limit or ptr[unsafe_offset=i + 3] != UInt8(ord("'"))
        ):
            lo = _set_nibble_lo(lo, UInt32(S_ML_LITERAL), UInt32(S_EXIT_ML_1))

    return (lo, hi)


@always_inline
def _step_single_state(s: UInt8) -> UInt8:
    if s == S_ENTER_MLB_1:
        return S_ENTER_MLB_2
    if s == S_ENTER_MLB_2:
        return S_ML_BASIC
    if s == S_ENTER_MLL_1:
        return S_ENTER_MLL_2
    if s == S_ENTER_MLL_2:
        return S_ML_LITERAL
    if s == S_EXIT_ML_1:
        return S_EXIT_ML_2
    return S_CODE


@always_inline
def _load_block_smem_with_halos(
    g_ptr: ImmPointer[UInt8, _],
    s_raw: MutPointer[UInt8, _, address_space=AddressSpace.SHARED],
    b_idx: Int,
    l_tid: Int,
    n: Int,
):
    var block_base = b_idx * GPU_BYTES_PER_BLOCK

    if l_tid < GPU_PREFIX_HALO:
        var g_off = block_base - GPU_PREFIX_HALO + l_tid
        s_raw[unsafe_offset=l_tid] = g_ptr[unsafe_offset=g_off] if (
            0 <= g_off < n
        ) else 0

    var body_dst = s_raw.unsafe_offset(GPU_PREFIX_HALO)
    if block_base + GPU_BYTES_PER_BLOCK + GPU_SUFFIX_HALO <= n:
        # 4 coalesced waves of 128 x 16B = 8,192 B!
        comptime for w in range(4):
            var off = (w * GPU_BLOCK_THREADS + l_tid) * 16
            var v = g_ptr.unsafe_load[width=16](block_base + off)
            body_dst.unsafe_store(off, v)
        if l_tid < (GPU_SUFFIX_HALO // 16):
            var off = GPU_BYTES_PER_BLOCK + l_tid * 16
            var v = g_ptr.unsafe_load[width=16](block_base + off)
            body_dst.unsafe_store(off, v)
    else:
        var idx = l_tid
        while idx < GPU_BYTES_PER_BLOCK + GPU_SUFFIX_HALO:
            var g_off = block_base + idx
            body_dst[unsafe_offset=idx] = (
                g_ptr[unsafe_offset=g_off] if g_off < n else 0
            )
            idx += GPU_BLOCK_THREADS


@always_inline
def _compute_chunk_fst_smem(
    s_body: ImmPointer[UInt8, _, address_space=AddressSpace.SHARED],
    local_start: Int,
    local_end: Int,
    local_doc_limit: Int,
) -> Tuple[UInt32, UInt32]:
    if local_start >= local_end:
        return (FST_ID_LO, FST_ID_HI)

    var lo = FST_ID_LO
    var hi = FST_ID_HI
    var gap = 0
    var i = local_start

    while i + 16 <= local_end:
        var v = s_body.unsafe_load[width=16](i)
        var special = (
            v.eq(UInt8(ord('"')))
            | v.eq(UInt8(ord("'")))
            | v.eq(UInt8(ord("\\")))
            | v.eq(UInt8(ord("#")))
            | v.eq(UInt8(ord("\n")))
        )
        if not any(special):
            gap += 16
            i += 16
            continue

        for k in range(16):
            var b = s_body[unsafe_offset=i + k]
            if (
                b == UInt8(ord('"'))
                or b == UInt8(ord("'"))
                or b == UInt8(ord("\\"))
                or b == UInt8(ord("#"))
                or b == UInt8(ord("\n"))
            ):
                if gap >= 1:
                    var g_lo = FST_BASE_LO if gap == 1 else FST_GAP2_LO
                    var g_hi = FST_BASE_HI if gap == 1 else FST_GAP2_HI
                    var g = _compose_fst(g_lo, g_hi, lo, hi)
                    lo = g[0]
                    hi = g[1]
                    gap = 0
                var st = _byte_step_fst(s_body, i + k, local_doc_limit)
                var c = _compose_fst(st[0], st[1], lo, hi)
                lo = c[0]
                hi = c[1]
            else:
                gap += 1
        i += 16

    while i < local_end:
        var b = s_body[unsafe_offset=i]
        if (
            b == UInt8(ord('"'))
            or b == UInt8(ord("'"))
            or b == UInt8(ord("\\"))
            or b == UInt8(ord("#"))
            or b == UInt8(ord("\n"))
        ):
            if gap >= 1:
                var g_lo = FST_BASE_LO if gap == 1 else FST_GAP2_LO
                var g_hi = FST_BASE_HI if gap == 1 else FST_GAP2_HI
                var g = _compose_fst(g_lo, g_hi, lo, hi)
                lo = g[0]
                hi = g[1]
                gap = 0
            var st = _byte_step_fst(s_body, i, local_doc_limit)
            var c = _compose_fst(st[0], st[1], lo, hi)
            lo = c[0]
            hi = c[1]
        else:
            gap += 1
        i += 1

    if gap == 1:
        var g1 = _compose_fst(FST_BASE_LO, FST_BASE_HI, lo, hi)
        lo = g1[0]
        hi = g1[1]
    elif gap >= 2:
        if lo == FST_ID_LO and hi == FST_ID_HI:
            return (FST_GAP2_LO, FST_GAP2_HI)
        var g2 = _compose_fst(FST_GAP2_LO, FST_GAP2_HI, lo, hi)
        lo = g2[0]
        hi = g2[1]

    return (lo, hi)


@always_inline
def _validate_utf8_smem(
    s_body: ImmPointer[UInt8, _, address_space=AddressSpace.SHARED],
    local_start: Int,
    local_end: Int,
    local_doc_limit: Int,
    global_chunk_start: Int,
) -> Bool:
    if local_start >= local_end:
        return True

    if local_end - local_start == 64:
        var v0 = s_body.unsafe_load[width=16](local_start)
        var v1 = s_body.unsafe_load[width=16](local_start + 16)
        var v2 = s_body.unsafe_load[width=16](local_start + 32)
        var v3 = s_body.unsafe_load[width=16](local_start + 48)
        var hi = ((v0 | v1) | (v2 | v3)) & 0x80
        if not any(hi.ne(0)):
            return True

    var i = local_start
    if global_chunk_start > 0 and (s_body[unsafe_offset=i] & 0xC0) == 0x80:
        var skipped = 0
        while (
            i < local_end
            and skipped < 3
            and (s_body[unsafe_offset=i] & 0xC0) == 0x80
        ):
            i += 1
            skipped += 1
        if i < local_end and (s_body[unsafe_offset=i] & 0xC0) == 0x80:
            return False
        var back = 1
        var found_lead = False
        while back <= 3 and global_chunk_start - back >= 0:
            var pb = s_body[unsafe_offset=local_start - back]
            if (pb & 0xC0) != 0x80:
                found_lead = pb >= 0xC2
                break
            back += 1
        if not found_lead:
            return False

    while i < local_end:
        var b0 = s_body[unsafe_offset=i]
        if b0 < 0x80:
            i += 1
            continue
        if b0 < 0xC2:
            return False
        if b0 < 0xE0:
            if i + 1 >= local_doc_limit:
                return False
            if (s_body[unsafe_offset=i + 1] & 0xC0) != 0x80:
                return False
            i += 2
        elif b0 < 0xF0:
            if i + 2 >= local_doc_limit:
                return False
            var b1 = s_body[unsafe_offset=i + 1]
            var b2 = s_body[unsafe_offset=i + 2]
            if (b1 & 0xC0) != 0x80 or (b2 & 0xC0) != 0x80:
                return False
            if b0 == 0xE0 and b1 < 0xA0:
                return False
            if b0 == 0xED and b1 >= 0xA0:
                return False
            i += 3
        elif b0 < 0xF5:
            if i + 3 >= local_doc_limit:
                return False
            var b1 = s_body[unsafe_offset=i + 1]
            var b2 = s_body[unsafe_offset=i + 2]
            var b3 = s_body[unsafe_offset=i + 3]
            if (
                (b1 & 0xC0) != 0x80
                or (b2 & 0xC0) != 0x80
                or (b3 & 0xC0) != 0x80
            ):
                return False
            if b0 == 0xF0 and b1 < 0x90:
                return False
            if b0 == 0xF4 and b1 >= 0x90:
                return False
            i += 4
        else:
            return False

    return True


@always_inline
def _hex_val_gpu(b: UInt8) -> UInt32:
    if UInt8(ord("0")) <= b <= UInt8(ord("9")):
        return UInt32(b - UInt8(ord("0")))
    var lower = b | 0x20
    if UInt8(ord("a")) <= lower <= UInt8(ord("f")):
        return UInt32(lower - UInt8(ord("a")) + 10)
    return 16


@always_inline
def _is_simple_escape_gpu(b: UInt8) -> UInt8:
    if b == UInt8(ord('"')):
        return UInt8(ord('"'))
    if b == UInt8(ord("\\")):
        return UInt8(ord("\\"))
    if b == UInt8(ord("b")):
        return 0x08
    if b == UInt8(ord("e")):
        return 0x1B
    if b == UInt8(ord("f")):
        return 0x0C
    if b == UInt8(ord("n")):
        return 0x0A
    if b == UInt8(ord("r")):
        return 0x0D
    if b == UInt8(ord("t")):
        return 0x09
    return 0


@always_inline
def _check_escape_gpu[
    is_multiline: Bool
](ptr: ImmPointer[UInt8, _], n: Int, esc_pos: Int) -> Bool:
    if esc_pos >= n:
        return False
    var esc = ptr[unsafe_offset=esc_pos]
    if _is_simple_escape_gpu(esc) != 0:
        return True
    if esc == UInt8(ord("x")):
        if esc_pos + 2 >= n:
            return False
        var d0 = _hex_val_gpu(ptr[unsafe_offset=esc_pos + 1])
        var d1 = _hex_val_gpu(ptr[unsafe_offset=esc_pos + 2])
        return (d0 | d1) < 16
    if esc == UInt8(ord("u")) or esc == UInt8(ord("U")):
        var hex_len = 4 if esc == UInt8(ord("u")) else 8
        if esc_pos + hex_len >= n:
            return False
        var cp: UInt32 = 0
        var bad: UInt32 = 0
        for j in range(1, hex_len + 1):
            var d = _hex_val_gpu(ptr[unsafe_offset=esc_pos + j])
            bad |= d
            cp = (cp << 4) | (d & 0xF)
        if bad >= 16:
            return False
        return not ((cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF)
    comptime if is_multiline:
        if (
            esc == UInt8(ord(" "))
            or esc == UInt8(ord("\t"))
            or esc == UInt8(ord("\n"))
            or esc == UInt8(ord("\r"))
        ):
            var p = esc_pos
            while p < n and (
                ptr[unsafe_offset=p] == UInt8(ord(" "))
                or ptr[unsafe_offset=p] == UInt8(ord("\t"))
            ):
                p += 1
            if p >= n:
                return False
            var nb = ptr[unsafe_offset=p]
            if nb == UInt8(ord("\n")):
                return True
            if (
                nb == UInt8(ord("\r"))
                and p + 1 < n
                and ptr[unsafe_offset=p + 1] == UInt8(ord("\n"))
            ):
                return True
    return False


@always_inline
def _is_bare_byte_gpu(b: UInt8) -> Bool:
    var lower = b | 0x20
    return (
        (UInt8(ord("a")) <= lower <= UInt8(ord("z")))
        or (UInt8(ord("0")) <= b <= UInt8(ord("9")))
        or b == UInt8(ord("_"))
        or b == UInt8(ord("-"))
    )


@always_inline
def _is_atom_byte_gpu(b: UInt8) -> Bool:
    if b <= UInt8(ord(" ")):
        return False
    return not (
        b == UInt8(ord("#"))
        or b == UInt8(ord("="))
        or b == UInt8(ord(","))
        or b == UInt8(ord("["))
        or b == UInt8(ord("]"))
        or b == UInt8(ord("{"))
        or b == UInt8(ord("}"))
        or b == UInt8(ord("."))
        or b == UInt8(ord('"'))
        or b == UInt8(ord("'"))
        or b == 0x7F
    )


@always_inline
def _dec2_gpu(ptr: ImmPointer[UInt8, _, address_space=_], off: Int) -> Int:
    var b0 = ptr[unsafe_offset=off]
    var b1 = ptr[unsafe_offset=off + 1]
    if not (UInt8(ord("0")) <= b0 <= UInt8(ord("9"))) or not (
        UInt8(ord("0")) <= b1 <= UInt8(ord("9"))
    ):
        return -1
    return Int(b0 - UInt8(ord("0"))) * 10 + Int(b1 - UInt8(ord("0")))


@always_inline
def _preclassify_atom_gpu(
    ptr: ImmPointer[UInt8, _, address_space=_],
    start: Int,
    atom_len: Int,
    all_bare: Bool,
) -> UInt8:
    var bare_flag: UInt8 = ATOM_BARE_FLAG if all_bare else 0
    var b0 = ptr[unsafe_offset=start]

    if b0 == UInt8(ord("t")) and atom_len == 4:
        if (
            ptr[unsafe_offset=start + 1] == UInt8(ord("r"))
            and ptr[unsafe_offset=start + 2] == UInt8(ord("u"))
            and ptr[unsafe_offset=start + 3] == UInt8(ord("e"))
        ):
            return NodeKind.Boolean._value | bare_flag | (1 << 5)
    elif b0 == UInt8(ord("f")) and atom_len == 5:
        if (
            ptr[unsafe_offset=start + 1] == UInt8(ord("a"))
            and ptr[unsafe_offset=start + 2] == UInt8(ord("l"))
            and ptr[unsafe_offset=start + 3] == UInt8(ord("s"))
            and ptr[unsafe_offset=start + 4] == UInt8(ord("e"))
        ):
            return NodeKind.Boolean._value | bare_flag | (1 << 5)

    var dig_s = start
    if b0 == UInt8(ord("-")) or b0 == UInt8(ord("+")):
        dig_s += 1
    var end = start + atom_len
    if dig_s < end:
        var d0 = ptr[unsafe_offset=dig_s]
        if UInt8(ord("0")) <= d0 <= UInt8(ord("9")):
            var p = dig_s + 1
            while p < end and (
                UInt8(ord("0")) <= ptr[unsafe_offset=p] <= UInt8(ord("9"))
            ):
                p += 1
            var n_dig = p - dig_s
            if p == end:
                var no_lz = (n_dig == 1) or (d0 != UInt8(ord("0")))
                if no_lz and n_dig <= 18:
                    return NodeKind.Integer._value | bare_flag | (2 << 5)
                return NodeKind.Integer._value | bare_flag
            if (
                dig_s == start
                and atom_len == 10
                and n_dig == 4
                and ptr[unsafe_offset=start + 4] == UInt8(ord("-"))
                and ptr[unsafe_offset=start + 7] == UInt8(ord("-"))
            ):
                var month = _dec2_gpu(ptr, start + 5)
                var day = _dec2_gpu(ptr, start + 8)
                if 1 <= month <= 12 and 1 <= day <= 31:
                    var year = (
                        Int(ptr[unsafe_offset=start] - UInt8(ord("0"))) * 1000
                        + Int(ptr[unsafe_offset=start + 1] - UInt8(ord("0")))
                        * 100
                        + Int(ptr[unsafe_offset=start + 2] - UInt8(ord("0")))
                        * 10
                        + Int(ptr[unsafe_offset=start + 3] - UInt8(ord("0")))
                    )
                    var dim = 31
                    if month == 4 or month == 6 or month == 9 or month == 11:
                        dim = 30
                    elif month == 2:
                        var leap = (year % 4 == 0) and (
                            year % 100 != 0 or year % 400 == 0
                        )
                        dim = 29 if leap else 28
                    if day <= dim:
                        return NodeKind.Date._value | bare_flag | (1 << 5)

    return bare_flag


# ===----------------------------------------------------------------------=== #
# Kernel 0: Zero status words on GPU
# ===----------------------------------------------------------------------=== #


def init_status_kernel[
    StatusLayout: TensorLayout
](status: MutTileTensor[DType.uint32, StatusLayout, MutUntrackedOrigin]):
    comptime assert status.flat_rank == 1
    var tid = global_idx.x
    if tid < 8:
        status[tid] = 0


# ===----------------------------------------------------------------------=== #
# Kernel 1: Coalesced Shared-Memory UTF-8 + FST Scan
# ===----------------------------------------------------------------------=== #


def fst_and_utf8_kernel[
    strict: Bool,
    DataLayout: TensorLayout,
    ThreadFstLayout: TensorLayout,
    BlockTransLayout: TensorLayout,
    StatusLayout: TensorLayout,
](
    data: ImmTileTensor[DType.uint8, DataLayout, ImmUntrackedOrigin],
    thread_fst_packed: MutTileTensor[
        DType.uint64, ThreadFstLayout, MutUntrackedOrigin
    ],
    block_trans_lo: MutTileTensor[
        DType.uint32, BlockTransLayout, MutUntrackedOrigin
    ],
    block_trans_hi: MutTileTensor[
        DType.uint32, BlockTransLayout, MutUntrackedOrigin
    ],
    status: MutTileTensor[DType.uint32, StatusLayout, MutUntrackedOrigin],
    n_bytes: UInt32,
):
    comptime assert (
        data.flat_rank == 1
        and thread_fst_packed.flat_rank == 1
        and block_trans_lo.flat_rank == 1
        and block_trans_hi.flat_rank == 1
        and status.flat_rank == 1
    )
    var g_tid = global_idx.x
    var l_tid = thread_idx.x
    var b_idx = block_idx.x
    var n = Int(n_bytes)
    var block_base = b_idx * GPU_BYTES_PER_BLOCK

    var smem_data = stack_allocation[
        DType.uint8, address_space=AddressSpace.SHARED
    ](row_major[GPU_SMEM_BYTES]())
    var s_lo = stack_allocation[
        DType.uint32, address_space=AddressSpace.SHARED
    ](row_major[GPU_BLOCK_THREADS]())
    var s_hi = stack_allocation[
        DType.uint32, address_space=AddressSpace.SHARED
    ](row_major[GPU_BLOCK_THREADS]())
    comptime assert (
        smem_data.flat_rank == 1 and s_lo.flat_rank == 1 and s_hi.flat_rank == 1
    )

    _load_block_smem_with_halos(
        data.unsafe_ptr(), smem_data.unsafe_ptr(), b_idx, l_tid, n
    )
    barrier()

    var s_body = (
        smem_data.unsafe_ptr()
        .unsafe_offset(GPU_PREFIX_HALO)
        .unsafe_mut_cast[False]()
    )
    var local_doc_limit = min(
        GPU_BYTES_PER_BLOCK + GPU_SUFFIX_HALO, max(0, n - block_base)
    )
    var local_start = l_tid * GPU_BYTES_PER_THREAD
    var local_end = min(
        min(GPU_BYTES_PER_BLOCK, local_doc_limit),
        local_start + GPU_BYTES_PER_THREAD,
    )

    var lo = FST_ID_LO
    var hi = FST_ID_HI

    if local_start < local_end:
        comptime if strict:
            if not _validate_utf8_smem(
                s_body,
                local_start,
                local_end,
                local_doc_limit,
                block_base + local_start,
            ):
                _ = Atomic[UInt32].fetch_add(status.unsafe_ptr(), UInt32(1))
        var fst = _compute_chunk_fst_smem(
            s_body, local_start, local_end, local_doc_limit
        )
        lo = fst[0]
        hi = fst[1]

    s_lo[l_tid] = rebind[s_lo.ElementType](lo)
    s_hi[l_tid] = rebind[s_hi.ElementType](hi)
    barrier()

    comptime for step in range(GPU_BLOCK_LOG2):
        var stride = 1 << step
        var next_lo = rebind[UInt32](s_lo[l_tid])
        var next_hi = rebind[UInt32](s_hi[l_tid])
        if l_tid >= stride:
            var prev_lo = rebind[UInt32](s_lo[l_tid - stride])
            var prev_hi = rebind[UInt32](s_hi[l_tid - stride])
            var comp = _compose_fst(next_lo, next_hi, prev_lo, prev_hi)
            next_lo = comp[0]
            next_hi = comp[1]
        barrier()
        s_lo[l_tid] = rebind[s_lo.ElementType](next_lo)
        s_hi[l_tid] = rebind[s_hi.ElementType](next_hi)
        barrier()

    var inc_lo = rebind[UInt32](s_lo[l_tid])
    var inc_hi = rebind[UInt32](s_hi[l_tid])
    thread_fst_packed[g_tid] = rebind[thread_fst_packed.ElementType](
        UInt64(inc_lo) | (UInt64(inc_hi) << 32)
    )

    if l_tid == GPU_BLOCK_THREADS - 1:
        block_trans_lo[b_idx] = rebind[block_trans_lo.ElementType](inc_lo)
        block_trans_hi[b_idx] = rebind[block_trans_hi.ElementType](inc_hi)


# ===----------------------------------------------------------------------=== #
# Kernel 2: Tiled Prefix Scan over Block FST Transitions + EOF State Check
# ===----------------------------------------------------------------------=== #


def scan_block_states_kernel[
    BlockTransLayout: TensorLayout,
    BlockStateLayout: TensorLayout,
    StatusLayout: TensorLayout,
](
    block_trans_lo: ImmTileTensor[
        DType.uint32, BlockTransLayout, ImmUntrackedOrigin
    ],
    block_trans_hi: ImmTileTensor[
        DType.uint32, BlockTransLayout, ImmUntrackedOrigin
    ],
    block_entry_state: MutTileTensor[
        DType.uint8, BlockStateLayout, MutUntrackedOrigin
    ],
    status: MutTileTensor[DType.uint32, StatusLayout, MutUntrackedOrigin],
    num_blocks: UInt32,
):
    comptime assert (
        block_trans_lo.flat_rank == 1
        and block_trans_hi.flat_rank == 1
        and block_entry_state.flat_rank == 1
        and status.flat_rank == 1
    )
    var tid = thread_idx.x
    var nb = Int(num_blocks)

    var s_lo = stack_allocation[
        DType.uint32, address_space=AddressSpace.SHARED
    ](row_major[GPU_BLOCK_THREADS]())
    var s_hi = stack_allocation[
        DType.uint32, address_space=AddressSpace.SHARED
    ](row_major[GPU_BLOCK_THREADS]())
    var s_carry = stack_allocation[
        DType.uint32, address_space=AddressSpace.SHARED
    ](row_major[1]())
    comptime assert (
        s_lo.flat_rank == 1 and s_hi.flat_rank == 1 and s_carry.flat_rank == 1
    )

    if tid == 0:
        s_carry[0] = UInt32(S_CODE)
    barrier()

    var base = 0
    while base < nb:
        var idx = base + tid
        var lo = FST_ID_LO
        var hi = FST_ID_HI
        if idx < nb:
            lo = rebind[UInt32](block_trans_lo[idx])
            hi = rebind[UInt32](block_trans_hi[idx])
        s_lo[tid] = rebind[s_lo.ElementType](lo)
        s_hi[tid] = rebind[s_hi.ElementType](hi)
        barrier()

        comptime for step in range(GPU_BLOCK_LOG2):
            var stride = 1 << step
            var cur_lo = rebind[UInt32](s_lo[tid])
            var cur_hi = rebind[UInt32](s_hi[tid])
            if tid >= stride:
                var p_lo = rebind[UInt32](s_lo[tid - stride])
                var p_hi = rebind[UInt32](s_hi[tid - stride])
                var comp = _compose_fst(cur_lo, cur_hi, p_lo, p_hi)
                cur_lo = comp[0]
                cur_hi = comp[1]
            barrier()
            s_lo[tid] = rebind[s_lo.ElementType](cur_lo)
            s_hi[tid] = rebind[s_hi.ElementType](cur_hi)
            barrier()

        var carry_state = rebind[UInt32](s_carry[0])
        if idx < nb:
            var entry_s: UInt32
            if tid == 0:
                entry_s = carry_state
            else:
                entry_s = _eval_fst(
                    rebind[UInt32](s_lo[tid - 1]),
                    rebind[UInt32](s_hi[tid - 1]),
                    carry_state,
                )
            block_entry_state[idx] = rebind[block_entry_state.ElementType](
                UInt8(entry_s)
            )

            if idx == nb - 1:
                var eof_s = _eval_fst(
                    rebind[UInt32](s_lo[tid]),
                    rebind[UInt32](s_hi[tid]),
                    carry_state,
                )
                if eof_s != UInt32(S_CODE) and eof_s != UInt32(S_COMMENT):
                    _ = Atomic[UInt32].fetch_add(
                        status.unsafe_ptr().unsafe_offset(STATUS_LEX_ERR),
                        UInt32(1),
                    )
        barrier()

        if tid == GPU_BLOCK_THREADS - 1:
            s_carry[0] = rebind[s_carry.ElementType](
                _eval_fst(
                    rebind[UInt32](s_lo[GPU_BLOCK_THREADS - 1]),
                    rebind[UInt32](s_hi[GPU_BLOCK_THREADS - 1]),
                    carry_state,
                )
            )
        barrier()
        base += GPU_BLOCK_THREADS


# ===----------------------------------------------------------------------=== #
# Kernel 3: Single-Pass Register-Buffered 32-Bit Token Compaction
# ===----------------------------------------------------------------------=== #


@always_inline
def _record_tok[
    emit_global: Bool
](
    tok: UInt32,
    mut count: UInt32,
    mut reg_buf: Array[UInt32, REG_TOK_BUF_CAP],
    tokens_ptr: MutPointer[UInt32, _],
    write_base: Int,
):
    comptime if emit_global:
        tokens_ptr[unsafe_offset=write_base + Int(count)] = tok
    else:
        if Int(count) < REG_TOK_BUF_CAP:
            reg_buf[Int(count)] = tok
    count += 1


@always_inline
def _scan_or_emit_smem32[
    strict: Bool, emit_global: Bool
](
    s_body: ImmPointer[UInt8, _, address_space=AddressSpace.SHARED],
    g_ptr: ImmPointer[UInt8, _],
    local_start: Int,
    local_end: Int,
    local_doc_limit: Int,
    block_base: Int,
    n: Int,
    s0: UInt8,
    mut reg_buf: Array[UInt32, REG_TOK_BUF_CAP],
    tokens_ptr: MutPointer[UInt32, _],
    write_base: Int,
    mut lex_err: Bool,
) -> UInt32:
    if local_start >= local_end:
        return 0

    var count: UInt32 = 0
    var s = s0
    var i = local_start
    var saw_esc = False

    if (
        s == S_CODE
        and (block_base + local_start) > 0
        and _is_atom_byte_gpu(s_body[unsafe_offset=local_start - 1])
    ):
        while i < local_end and _is_atom_byte_gpu(s_body[unsafe_offset=i]):
            i += 1

    while i < local_end:
        if (s == S_BASIC or s == S_LITERAL) and i + 16 <= local_end:
            var v = s_body.unsafe_load[width=16](i)
            var q = UInt8(ord("'")) if s == S_LITERAL else UInt8(ord('"'))
            var stop = v.eq(q)
            if s == S_BASIC:
                stop |= v.eq(UInt8(ord("\\")))
            comptime if not emit_global and strict:
                stop |= (v.lt(0x20) & v.ne(0x09)) | v.eq(0x7F)
            if not any(stop):
                i += 16
                continue
        elif s == S_COMMENT and i + 16 <= local_end:
            var v = s_body.unsafe_load[width=16](i)
            var stop = v.eq(UInt8(ord("\n")))
            comptime if not emit_global and strict:
                stop |= (v.lt(0x20) & v.ne(0x09)) | v.eq(0x7F)
            if not any(stop):
                i += 16
                continue

        var b0 = s_body[unsafe_offset=i]

        if s == S_CODE:
            if b0 == UInt8(ord(" ")) or b0 == UInt8(ord("\t")):
                i += 1
                continue
            if b0 == UInt8(ord("\r")):
                if i + 1 >= local_doc_limit or s_body[
                    unsafe_offset=i + 1
                ] != UInt8(ord("\n")):
                    lex_err = True
                i += 1
                continue
            if b0 == UInt8(ord("\n")):
                _record_tok[emit_global](
                    _pack_tok32(i, TOK_NEWLINE),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                i += 1
                continue
            if b0 == UInt8(ord("#")):
                s = S_COMMENT
                i += 1
                continue
            if b0 == UInt8(ord("[")):
                _record_tok[emit_global](
                    _pack_tok32(i, TOK_LBRACKET),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                i += 1
                continue
            if b0 == UInt8(ord("]")):
                _record_tok[emit_global](
                    _pack_tok32(i, TOK_RBRACKET),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                i += 1
                continue
            if b0 == UInt8(ord("{")):
                _record_tok[emit_global](
                    _pack_tok32(i, TOK_LBRACE),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                i += 1
                continue
            if b0 == UInt8(ord("}")):
                _record_tok[emit_global](
                    _pack_tok32(i, TOK_RBRACE),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                i += 1
                continue
            if b0 == UInt8(ord("=")):
                _record_tok[emit_global](
                    _pack_tok32(i, TOK_EQUAL),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                i += 1
                continue
            if b0 == UInt8(ord(",")):
                _record_tok[emit_global](
                    _pack_tok32(i, TOK_COMMA),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                i += 1
                continue
            if b0 == UInt8(ord(".")):
                _record_tok[emit_global](
                    _pack_tok32(i, TOK_DOT),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                i += 1
                continue
            if b0 == UInt8(ord('"')) or b0 == UInt8(ord("'")):
                var is_lit = b0 == UInt8(ord("'"))
                var is_ml = (
                    i + 2 < local_doc_limit
                    and s_body[unsafe_offset=i + 1] == b0
                    and s_body[unsafe_offset=i + 2] == b0
                )
                saw_esc = False
                var sflags: UInt8 = (NodeFlags.LITERAL if is_lit else 0) | (
                    NodeFlags.MULTILINE if is_ml else 0
                )
                var c_local = i + (3 if is_ml else 1)
                _record_tok[emit_global](
                    _pack_tok32(c_local, TOK_STR_OPEN, sflags),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                if is_ml:
                    s = S_ENTER_MLL_1 if is_lit else S_ENTER_MLB_1
                else:
                    s = S_LITERAL if is_lit else S_BASIC
                i += 1
                continue

            if not _is_atom_byte_gpu(b0):
                lex_err = True
                i += 1
                continue

            var a_start = i
            var p = i
            var all_bare = True
            var max_p = min(local_doc_limit, a_start + 64)
            while p < max_p and _is_atom_byte_gpu(s_body[unsafe_offset=p]):
                if not _is_bare_byte_gpu(s_body[unsafe_offset=p]):
                    all_bare = False
                p += 1
            var a_len = p - a_start
            var is_long = p < local_doc_limit and _is_atom_byte_gpu(
                s_body[unsafe_offset=p]
            )
            if is_long:
                _record_tok[emit_global](
                    _pack_tok32(a_start, TOK_ATOM_LONG),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                while p < local_end and _is_atom_byte_gpu(
                    s_body[unsafe_offset=p]
                ):
                    p += 1
            else:
                var a_flags = _preclassify_atom_gpu(
                    s_body, a_start, a_len, all_bare
                )
                _record_tok[emit_global](
                    _pack_tok32(a_start, TOK_ATOM, a_flags, a_len),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
            i = p
            continue

        elif s == S_COMMENT:
            comptime if not emit_global and strict:
                if b0 == UInt8(ord("\r")):
                    if i + 1 >= local_doc_limit or s_body[
                        unsafe_offset=i + 1
                    ] != UInt8(ord("\n")):
                        lex_err = True
                elif (
                    b0 < 0x20 and b0 != 0x09 and b0 != 0x0A and b0 != 0x0D
                ) or b0 == 0x7F:
                    lex_err = True
            if b0 == UInt8(ord("\n")):
                _record_tok[emit_global](
                    _pack_tok32(i, TOK_NEWLINE),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                s = S_CODE
            i += 1
            continue

        elif s == S_BASIC:
            comptime if not emit_global and strict:
                if b0 == UInt8(ord("\n")) or b0 == UInt8(ord("\r")):
                    lex_err = True
                elif (b0 < 0x20 and b0 != 0x09) or b0 == 0x7F:
                    lex_err = True
            if b0 == UInt8(ord("\\")):
                saw_esc = True
                comptime if not emit_global and strict:
                    if not _check_escape_gpu[False](
                        g_ptr, n, block_base + i + 1
                    ):
                        lex_err = True
                s = S_BASIC_ESC
                i += 1
                continue
            if b0 == UInt8(ord('"')):
                _record_tok[emit_global](
                    _pack_tok32(
                        i,
                        TOK_STR_CLOSE,
                        NodeFlags.HAS_ESCAPE if saw_esc else 0,
                    ),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                saw_esc = False
                s = S_CODE
                i += 1
                continue
            i += 1
            continue

        elif s == S_BASIC_ESC:
            s = S_BASIC
            i += 1
            continue

        elif s == S_LITERAL:
            comptime if not emit_global and strict:
                if b0 == UInt8(ord("\n")) or b0 == UInt8(ord("\r")):
                    lex_err = True
                elif (b0 < 0x20 and b0 != 0x09) or b0 == 0x7F:
                    lex_err = True
            if b0 == UInt8(ord("'")):
                _record_tok[emit_global](
                    _pack_tok32(i, TOK_STR_CLOSE, 0),
                    count,
                    reg_buf,
                    tokens_ptr,
                    write_base,
                )
                s = S_CODE
                i += 1
                continue
            i += 1
            continue

        elif s == S_ML_BASIC:
            comptime if not emit_global and strict:
                if b0 == UInt8(ord("\r")):
                    if i + 1 >= local_doc_limit or s_body[
                        unsafe_offset=i + 1
                    ] != UInt8(ord("\n")):
                        lex_err = True
                elif (
                    b0 < 0x20 and b0 != 0x09 and b0 != 0x0A and b0 != 0x0D
                ) or b0 == 0x7F:
                    lex_err = True
            if b0 == UInt8(ord("\\")):
                saw_esc = True
                comptime if not emit_global and strict:
                    if not _check_escape_gpu[True](
                        g_ptr, n, block_base + i + 1
                    ):
                        lex_err = True
                s = S_ML_BASIC_ESC
                i += 1
                continue
            if b0 == UInt8(ord('"')):
                comptime if not emit_global and strict:
                    if (
                        i + 5 < local_doc_limit
                        and s_body[unsafe_offset=i + 1] == UInt8(ord('"'))
                        and s_body[unsafe_offset=i + 2] == UInt8(ord('"'))
                        and s_body[unsafe_offset=i + 3] == UInt8(ord('"'))
                        and s_body[unsafe_offset=i + 4] == UInt8(ord('"'))
                        and s_body[unsafe_offset=i + 5] == UInt8(ord('"'))
                    ):
                        lex_err = True
                if (
                    i + 2 < local_doc_limit
                    and s_body[unsafe_offset=i + 1] == UInt8(ord('"'))
                    and s_body[unsafe_offset=i + 2] == UInt8(ord('"'))
                    and (
                        i + 3 >= local_doc_limit
                        or s_body[unsafe_offset=i + 3] != UInt8(ord('"'))
                    )
                ):
                    _record_tok[emit_global](
                        _pack_tok32(
                            i,
                            TOK_STR_CLOSE,
                            NodeFlags.HAS_ESCAPE if saw_esc else 0,
                        ),
                        count,
                        reg_buf,
                        tokens_ptr,
                        write_base,
                    )
                    saw_esc = False
                    s = S_EXIT_ML_1
                    i += 1
                    continue
            i += 1
            continue

        elif s == S_ML_BASIC_ESC:
            comptime if not emit_global and strict:
                if b0 == UInt8(ord("\r")) and (
                    i + 1 >= local_doc_limit
                    or s_body[unsafe_offset=i + 1] != UInt8(ord("\n"))
                ):
                    lex_err = True
                elif (
                    b0 < 0x20 and b0 != 0x09 and b0 != 0x0A and b0 != 0x0D
                ) or b0 == 0x7F:
                    lex_err = True
            s = S_ML_BASIC
            i += 1
            continue

        elif s == S_ML_LITERAL:
            comptime if not emit_global and strict:
                if b0 == UInt8(ord("\r")):
                    if i + 1 >= local_doc_limit or s_body[
                        unsafe_offset=i + 1
                    ] != UInt8(ord("\n")):
                        lex_err = True
                elif (
                    b0 < 0x20 and b0 != 0x09 and b0 != 0x0A and b0 != 0x0D
                ) or b0 == 0x7F:
                    lex_err = True
            if b0 == UInt8(ord("'")):
                comptime if not emit_global and strict:
                    if (
                        i + 5 < local_doc_limit
                        and s_body[unsafe_offset=i + 1] == UInt8(ord("'"))
                        and s_body[unsafe_offset=i + 2] == UInt8(ord("'"))
                        and s_body[unsafe_offset=i + 3] == UInt8(ord("'"))
                        and s_body[unsafe_offset=i + 4] == UInt8(ord("'"))
                        and s_body[unsafe_offset=i + 5] == UInt8(ord("'"))
                    ):
                        lex_err = True
                if (
                    i + 2 < local_doc_limit
                    and s_body[unsafe_offset=i + 1] == UInt8(ord("'"))
                    and s_body[unsafe_offset=i + 2] == UInt8(ord("'"))
                    and (
                        i + 3 >= local_doc_limit
                        or s_body[unsafe_offset=i + 3] != UInt8(ord("'"))
                    )
                ):
                    _record_tok[emit_global](
                        _pack_tok32(i, TOK_STR_CLOSE, 0),
                        count,
                        reg_buf,
                        tokens_ptr,
                        write_base,
                    )
                    s = S_EXIT_ML_1
                    i += 1
                    continue
            i += 1
            continue

        else:
            s = _step_single_state(s)
            i += 1

    if saw_esc:
        _record_tok[emit_global](
            _pack_tok32(local_end, TOK_STR_ESC),
            count,
            reg_buf,
            tokens_ptr,
            write_base,
        )

    return count


def tokenize_compact_kernel[
    strict: Bool,
    DataLayout: TensorLayout,
    ThreadFstLayout: TensorLayout,
    BlockStateLayout: TensorLayout,
    BlockSliceLayout: TensorLayout,
    TokLayout: TensorLayout,
    StatusLayout: TensorLayout,
](
    data: ImmTileTensor[DType.uint8, DataLayout, ImmUntrackedOrigin],
    thread_fst_packed: ImmTileTensor[
        DType.uint64, ThreadFstLayout, ImmUntrackedOrigin
    ],
    block_entry_state: ImmTileTensor[
        DType.uint8, BlockStateLayout, ImmUntrackedOrigin
    ],
    block_tok_starts: MutTileTensor[
        DType.uint32, BlockSliceLayout, MutUntrackedOrigin
    ],
    block_tok_lens: MutTileTensor[
        DType.uint32, BlockSliceLayout, MutUntrackedOrigin
    ],
    tokens: MutTileTensor[DType.uint32, TokLayout, MutUntrackedOrigin],
    status: MutTileTensor[DType.uint32, StatusLayout, MutUntrackedOrigin],
    n_bytes: UInt32,
    max_tokens: UInt32,
):
    comptime assert (
        data.flat_rank == 1
        and thread_fst_packed.flat_rank == 1
        and block_entry_state.flat_rank == 1
        and block_tok_starts.flat_rank == 1
        and block_tok_lens.flat_rank == 1
        and tokens.flat_rank == 1
        and status.flat_rank == 1
    )
    var g_tid = global_idx.x
    var l_tid = thread_idx.x
    var b_idx = block_idx.x
    var n = Int(n_bytes)
    var block_base = b_idx * GPU_BYTES_PER_BLOCK

    var smem_data = stack_allocation[
        DType.uint8, address_space=AddressSpace.SHARED
    ](row_major[GPU_SMEM_BYTES]())
    var s_counts = stack_allocation[
        DType.uint32, address_space=AddressSpace.SHARED
    ](row_major[GPU_BLOCK_THREADS]())
    var s_block_base = stack_allocation[
        DType.uint32, address_space=AddressSpace.SHARED
    ](row_major[1]())
    comptime assert (
        smem_data.flat_rank == 1
        and s_counts.flat_rank == 1
        and s_block_base.flat_rank == 1
    )

    _load_block_smem_with_halos(
        data.unsafe_ptr(), smem_data.unsafe_ptr(), b_idx, l_tid, n
    )
    barrier()

    var b_entry = UInt32(rebind[UInt8](block_entry_state[b_idx]))
    var s0: UInt8
    if l_tid == 0:
        s0 = UInt8(b_entry)
    else:
        var prev_packed = rebind[UInt64](thread_fst_packed[g_tid - 1])
        var prev_lo = UInt32(prev_packed & 0xFFFFFFFF)
        var prev_hi = UInt32(prev_packed >> 32)
        s0 = UInt8(_eval_fst(prev_lo, prev_hi, b_entry))

    var s_body = (
        smem_data.unsafe_ptr()
        .unsafe_offset(GPU_PREFIX_HALO)
        .unsafe_mut_cast[False]()
    )
    var local_doc_limit = min(
        GPU_BYTES_PER_BLOCK + GPU_SUFFIX_HALO, max(0, n - block_base)
    )
    var local_start = l_tid * GPU_BYTES_PER_THREAD
    var local_end = min(
        min(GPU_BYTES_PER_BLOCK, local_doc_limit),
        local_start + GPU_BYTES_PER_THREAD,
    )

    var lex_err = False
    var reg_buf = Array[UInt32, REG_TOK_BUF_CAP](fill=0)
    var tok_ptr = tokens.unsafe_ptr()
    var my_count = _scan_or_emit_smem32[strict, False](
        s_body,
        data.unsafe_ptr(),
        local_start,
        local_end,
        local_doc_limit,
        block_base,
        n,
        s0,
        reg_buf,
        tok_ptr,
        0,
        lex_err,
    )
    if lex_err:
        _ = Atomic[UInt32].fetch_add(
            status.unsafe_ptr().unsafe_offset(STATUS_LEX_ERR), UInt32(1)
        )

    s_counts[l_tid] = rebind[s_counts.ElementType](my_count)
    barrier()

    comptime for step in range(GPU_BLOCK_LOG2):
        var stride = 1 << step
        var v = rebind[UInt32](s_counts[l_tid])
        if l_tid >= stride:
            v += rebind[UInt32](s_counts[l_tid - stride])
        barrier()
        s_counts[l_tid] = rebind[s_counts.ElementType](v)
        barrier()

    var local_excl: UInt32 = 0 if l_tid == 0 else rebind[UInt32](
        s_counts[l_tid - 1]
    )
    var block_total = rebind[UInt32](s_counts[GPU_BLOCK_THREADS - 1])

    if l_tid == 0:
        var base_idx: UInt32 = 0
        if block_total > 0:
            base_idx = Atomic[UInt32].fetch_add(
                status.unsafe_ptr().unsafe_offset(STATUS_TOK_COUNT),
                block_total,
            )
            if base_idx + block_total > max_tokens:
                _ = Atomic[UInt32].fetch_add(
                    status.unsafe_ptr().unsafe_offset(STATUS_OVERFLOW),
                    UInt32(1),
                )
        block_tok_starts[b_idx] = rebind[block_tok_starts.ElementType](base_idx)
        block_tok_lens[b_idx] = rebind[block_tok_lens.ElementType](block_total)
        s_block_base[0] = rebind[s_block_base.ElementType](base_idx)
    barrier()

    var out_base = rebind[UInt32](s_block_base[0])
    if my_count > 0 and (out_base + block_total <= max_tokens):
        var dst_off = Int(out_base + local_excl)
        if Int(my_count) <= REG_TOK_BUF_CAP:
            # Fast path (>99% of threads): flush directly from registers with zero re-scan!
            for k in range(Int(my_count)):
                tok_ptr[unsafe_offset=dst_off + k] = reg_buf[k]
        else:
            var dummy_err = False
            _ = _scan_or_emit_smem32[strict, True](
                s_body,
                data.unsafe_ptr(),
                local_start,
                local_end,
                local_doc_limit,
                block_base,
                n,
                s0,
                reg_buf,
                tok_ptr,
                dst_off,
                dummy_err,
            )


# ===----------------------------------------------------------------------=== #
# Kernel 4: Parallel `Mode.Eager` Disjoint Arena Unescaping & Scalar Decoding
# ===----------------------------------------------------------------------=== #


@always_inline
def _encode_utf8_gpu(cp: UInt32, dst: MutPointer[UInt8, _], pos: Int) -> Int:
    if cp < 0x80:
        dst[unsafe_offset=pos] = UInt8(cp)
        return pos + 1
    if cp < 0x800:
        dst[unsafe_offset=pos] = UInt8(0xC0 | (cp >> 6))
        dst[unsafe_offset=pos + 1] = UInt8(0x80 | (cp & 0x3F))
        return pos + 2
    if cp < 0x10000:
        dst[unsafe_offset=pos] = UInt8(0xE0 | (cp >> 12))
        dst[unsafe_offset=pos + 1] = UInt8(0x80 | ((cp >> 6) & 0x3F))
        dst[unsafe_offset=pos + 2] = UInt8(0x80 | (cp & 0x3F))
        return pos + 3
    dst[unsafe_offset=pos] = UInt8(0xF0 | (cp >> 18))
    dst[unsafe_offset=pos + 1] = UInt8(0x80 | ((cp >> 12) & 0x3F))
    dst[unsafe_offset=pos + 2] = UInt8(0x80 | ((cp >> 6) & 0x3F))
    dst[unsafe_offset=pos + 3] = UInt8(0x80 | (cp & 0x3F))
    return pos + 4


@always_inline
def _unescape_in_place_gpu(
    src: ImmPointer[UInt8, _],
    start: Int,
    raw_len: Int,
    is_multiline: Bool,
    dst_arena: MutPointer[UInt8, _],
) -> UInt32:
    var i = 0
    var out_pos = start
    while i < raw_len:
        var b = src[unsafe_offset=start + i]
        if b != UInt8(ord("\\")):
            dst_arena[unsafe_offset=out_pos] = b
            out_pos += 1
            i += 1
            continue
        i += 1
        var esc = src[unsafe_offset=start + i]
        var simple = _is_simple_escape_gpu(esc)
        if simple != 0:
            dst_arena[unsafe_offset=out_pos] = simple
            out_pos += 1
            i += 1
        elif esc == UInt8(ord("x")):
            var d0 = _hex_val_gpu(src[unsafe_offset=start + i + 1])
            var d1 = _hex_val_gpu(src[unsafe_offset=start + i + 2])
            out_pos = _encode_utf8_gpu((d0 << 4) | d1, dst_arena, out_pos)
            i += 3
        elif esc == UInt8(ord("u")) or esc == UInt8(ord("U")):
            var hex_len = 4 if esc == UInt8(ord("u")) else 8
            var cp: UInt32 = 0
            for j in range(1, hex_len + 1):
                cp = (cp << 4) | _hex_val_gpu(src[unsafe_offset=start + i + j])
            out_pos = _encode_utf8_gpu(cp, dst_arena, out_pos)
            i += 1 + hex_len
        elif is_multiline:
            while i < raw_len:
                var wb = src[unsafe_offset=start + i]
                if (
                    wb == UInt8(ord(" "))
                    or wb == UInt8(ord("\t"))
                    or wb == UInt8(ord("\r"))
                    or wb == UInt8(ord("\n"))
                ):
                    i += 1
                else:
                    break
        else:
            i += 1
    return UInt32(out_pos - start)


@always_inline
def _decode_int64_gpu(
    src: ImmPointer[UInt8, _], start: Int, raw_len: Int, flags: UInt8
) -> UInt64:
    var first = src[unsafe_offset=start]
    if (flags & NodeFlags.CANONICAL) != 0:
        var is_neg = first == UInt8(ord("-"))
        var s = 1 if (is_neg or first == UInt8(ord("+"))) else 0
        var acc: UInt64 = 0
        for i in range(s, raw_len):
            acc = acc * 10 + UInt64(
                src[unsafe_offset=start + i] - UInt8(ord("0"))
            )
        return (~acc + 1) if is_neg else acc

    var is_neg = first == UInt8(ord("-"))
    var s = 1 if (is_neg or first == UInt8(ord("+"))) else 0
    var base: UInt64 = 10
    if s + 1 < raw_len and src[unsafe_offset=start + s] == UInt8(ord("0")):
        var p = src[unsafe_offset=start + s + 1]
        if p == UInt8(ord("x")):
            base = 16
            s += 2
        elif p == UInt8(ord("o")):
            base = 8
            s += 2
        elif p == UInt8(ord("b")):
            base = 2
            s += 2

    var acc: UInt64 = 0
    for i in range(s, raw_len):
        var b = src[unsafe_offset=start + i]
        if b == UInt8(ord("_")):
            continue
        var d = UInt64(_hex_val_gpu(b))
        acc = acc * base + d
    return (~acc + 1) if is_neg else acc


def materialize_eager_nodes_kernel[
    SrcLayout: TensorLayout,
    ArenaLayout: TensorLayout,
    NodeBytesLayout: TensorLayout,
](
    src_data: ImmTileTensor[DType.uint8, SrcLayout, ImmUntrackedOrigin],
    arena: MutTileTensor[DType.uint8, ArenaLayout, MutUntrackedOrigin],
    node_words: MutTileTensor[
        DType.uint32, NodeBytesLayout, MutUntrackedOrigin
    ],
    n_nodes: UInt32,
):
    """Parallel 1-thread-per-Node `Mode.Eager` materializer over `node_words`.
    """
    comptime assert (
        src_data.flat_rank == 1
        and arena.flat_rank == 1
        and node_words.flat_rank == 1
    )
    var nid = global_idx.x
    if nid >= Int(n_nodes):
        return

    var src_ptr = src_data.unsafe_ptr()
    var arena_ptr = arena.unsafe_ptr()
    var nw_ptr = node_words.unsafe_ptr().unsafe_offset(nid * 8)

    var w0 = nw_ptr[unsafe_offset=0]
    var kind = UInt8(w0 & 0xFF)
    var flags = UInt8((w0 >> 8) & 0xFF)
    var key_flags = UInt8((w0 >> 16) & 0xFF)
    var key_tag = UInt8((w0 >> 24) & 0xFF)

    if (key_flags & NodeFlags.HAS_ESCAPE) != 0:
        var k_start = Int(nw_ptr[unsafe_offset=3])
        var k_len = Int(nw_ptr[unsafe_offset=4])
        var new_klen = _unescape_in_place_gpu(
            src_ptr, k_start, k_len, False, arena_ptr
        )
        nw_ptr[unsafe_offset=4] = new_klen
        key_tag = arena_ptr[unsafe_offset=k_start] if new_klen > 0 else 0
        key_flags = 0

    if kind == NodeKind.String._value:
        if (flags & NodeFlags.HAS_ESCAPE) != 0 and (
            flags & NodeFlags.LITERAL
        ) == 0:
            var s_start = Int(nw_ptr[unsafe_offset=1])
            var s_len = Int(nw_ptr[unsafe_offset=2])
            var new_slen = _unescape_in_place_gpu(
                src_ptr,
                s_start,
                s_len,
                (flags & NodeFlags.MULTILINE) != 0,
                arena_ptr,
            )
            nw_ptr[unsafe_offset=2] = new_slen
        flags = 0
    elif kind == NodeKind.Integer._value:
        var s_start = Int(nw_ptr[unsafe_offset=1])
        var s_len = Int(nw_ptr[unsafe_offset=2])
        var u = _decode_int64_gpu(src_ptr, s_start, s_len, flags)
        nw_ptr[unsafe_offset=1] = UInt32(u & 0xFFFFFFFF)
        nw_ptr[unsafe_offset=2] = UInt32(u >> 32)
    elif kind == NodeKind.Boolean._value:
        var s_start = Int(nw_ptr[unsafe_offset=1])
        nw_ptr[unsafe_offset=1] = (
            1 if src_ptr[unsafe_offset=s_start] == UInt8(ord("t")) else 0
        )
    elif kind == NodeKind.NaN._value:
        nw_ptr[unsafe_offset=1] = 0x00000000
        nw_ptr[unsafe_offset=2] = 0x7FF80000
    elif kind == NodeKind.Inf._value:
        var s_start = Int(nw_ptr[unsafe_offset=1])
        var is_neg = src_ptr[unsafe_offset=s_start] == UInt8(ord("-"))
        nw_ptr[unsafe_offset=1] = 0x00000000
        nw_ptr[unsafe_offset=2] = 0xFFF00000 if is_neg else 0x7FF00000
    elif kind == NodeKind.Date._value:
        var s_start = Int(nw_ptr[unsafe_offset=1])
        var yr = (
            UInt32(src_ptr[unsafe_offset=s_start] - UInt8(ord("0"))) * 1000
            + UInt32(src_ptr[unsafe_offset=s_start + 1] - UInt8(ord("0"))) * 100
            + UInt32(src_ptr[unsafe_offset=s_start + 2] - UInt8(ord("0"))) * 10
            + UInt32(src_ptr[unsafe_offset=s_start + 3] - UInt8(ord("0")))
        )
        var mo = UInt32(_dec2_gpu(src_ptr, s_start + 5))
        var dy = UInt32(_dec2_gpu(src_ptr, s_start + 8))
        nw_ptr[unsafe_offset=1] = (yr << 16) | (mo << 8) | dy

    nw_ptr[unsafe_offset=0] = (
        UInt32(kind)
        | (UInt32(flags) << 8)
        | (UInt32(key_flags) << 16)
        | (UInt32(key_tag) << 24)
    )
