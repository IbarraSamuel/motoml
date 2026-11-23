"""Stateful GPU TOML 1.1 parser (`GpuTomlParser`), hybrid/eager GPU pipelines, and batch APIs.

Automatically detects Unified Memory GPUs (Apple Silicon Metal via `DeviceBuffer.unsafe_host_ptr()`)
for 28 GB/s zero-DMA host->device streaming writes and exact-count 32-bit token readback, while
falling back cleanly to pinned `HostBuffer` DMA on discrete PCIe GPUs (NVIDIA CUDA / AMD ROCm).
"""

from std.collections import Array, List, Optional, Span
from std.ffi import external_call
from std.math import align_up, ceildiv
from std.memory import Pointer, bitcast, unsafe_memcpy
from std.sys import has_accelerator
from max.gpu.host import DeviceBuffer, DeviceContext, HostBuffer
from layout import TileTensor, row_major
from motoml import Mode, Result, TomlDocument, TomlFile
from motoml.mmap_file import MappedFile
from motoml.tape.decode import (
    decode_datetime_unchecked,
    decode_float_unchecked,
    decode_time_unchecked,
)
from motoml.tape.key_index import KEY_ESCAPE_BIT
from motoml.tape.node import NO_NODE, Node, NodeFlags
from motoml.tape.reader import MAX_DOCUMENT_BYTES, _ParsedTape, _parse_tape
from motoml.types.document import _materialize
from motoml.types.store import _Store
from motoml.types.tempo import Date, DateTime, Offset
from .kernels import (
    GPU_BLOCK_THREADS,
    GPU_BYTES_PER_BLOCK,
    STATUS_LEX_ERR,
    STATUS_OVERFLOW,
    STATUS_TOK_COUNT,
    STATUS_UTF8_ERR,
    fst_and_utf8_kernel,
    init_status_kernel,
    materialize_eager_nodes_kernel,
    scan_block_states_kernel,
    tokenize_compact_kernel,
)
from .stage2 import _CachedBlockCursor, _Stage2Builder

comptime DEFAULT_MIN_GPU_BYTES: Int = 512 * 1024
comptime DEFAULT_MIN_GPU_EAGER_NODES: Int = 16_384


struct GpuTomlParser(Movable, not RegisterPassable):
    """Reusable GPU-accelerated TOML 1.1 parser owning a `DeviceContext` and pre-sized arenas.
    """

    var ctx: DeviceContext[]
    var min_gpu_bytes: Int
    var has_unified_memory: Bool

    var byte_cap: Int
    var block_cap: Int
    var tok_cap: Int
    var node_word_cap: Int

    var d_input: DeviceBuffer[DType.uint8]
    var d_arena: DeviceBuffer[DType.uint8]
    var d_thread_fst: DeviceBuffer[DType.uint64]
    var d_block_lo: DeviceBuffer[DType.uint32]
    var d_block_hi: DeviceBuffer[DType.uint32]
    var d_block_state: DeviceBuffer[DType.uint8]
    var d_block_starts: DeviceBuffer[DType.uint32]
    var d_block_lens: DeviceBuffer[DType.uint32]
    var d_tokens: DeviceBuffer[DType.uint32]
    var d_status: DeviceBuffer[DType.uint32]
    var d_node_words: DeviceBuffer[DType.uint32]

    # Pinned staging buffers used only on discrete PCIe GPUs (`not self.has_unified_memory`)
    var h_staging_in: Optional[HostBuffer[DType.uint8]]
    var h_staging_toks: Optional[HostBuffer[DType.uint32]]
    var h_staging_bs: Optional[HostBuffer[DType.uint32]]
    var h_staging_bl: Optional[HostBuffer[DType.uint32]]
    var h_staging_status: Optional[HostBuffer[DType.uint32]]

    # Pre-faulted L1/L2-cached CPU buffers for fast Stage-2 tree construction
    var cached_status: Array[UInt32, 8]
    var cached_block_starts: List[UInt32]
    var cached_block_lens: List[UInt32]
    var cached_tokens: List[UInt32]
    var cached_packed_bytes: List[Byte]

    def __init__(
        out self,
        initial_capacity_bytes: Int = 2 * 1024 * 1024,
        min_gpu_bytes: Int = DEFAULT_MIN_GPU_BYTES,
    ) raises:
        comptime assert (
            has_accelerator()
        ), "GpuTomlParser requires a GPU accelerator"
        self.ctx = DeviceContext()
        self.min_gpu_bytes = min_gpu_bytes

        var b_cap = max(
            64 * 1024, align_up(initial_capacity_bytes, GPU_BYTES_PER_BLOCK)
        )
        var blk_cap = max(16, ceildiv(b_cap, GPU_BYTES_PER_BLOCK))
        var th_cap = blk_cap * GPU_BLOCK_THREADS
        var t_cap = max(16 * 1024, b_cap // 2)
        var nw_cap = max(16 * 1024, (b_cap // 12) * 8)

        self.byte_cap = b_cap
        self.block_cap = blk_cap
        self.tok_cap = t_cap
        self.node_word_cap = nw_cap

        self.d_input = self.ctx.enqueue_create_buffer[DType.uint8](b_cap)
        self.d_arena = self.ctx.enqueue_create_buffer[DType.uint8](b_cap)
        self.d_thread_fst = self.ctx.enqueue_create_buffer[DType.uint64](th_cap)
        self.d_block_lo = self.ctx.enqueue_create_buffer[DType.uint32](blk_cap)
        self.d_block_hi = self.ctx.enqueue_create_buffer[DType.uint32](blk_cap)
        self.d_block_state = self.ctx.enqueue_create_buffer[DType.uint8](
            blk_cap
        )
        self.d_block_starts = self.ctx.enqueue_create_buffer[DType.uint32](
            blk_cap
        )
        self.d_block_lens = self.ctx.enqueue_create_buffer[DType.uint32](
            blk_cap
        )
        self.d_tokens = self.ctx.enqueue_create_buffer[DType.uint32](t_cap)
        self.d_status = self.ctx.enqueue_create_buffer[DType.uint32](8)
        self.d_node_words = self.ctx.enqueue_create_buffer[DType.uint32](nw_cap)
        self.ctx.synchronize()

        var uma: Bool
        try:
            _ = self.d_status.unsafe_host_ptr()
            uma = True
        except:
            uma = False
        self.has_unified_memory = uma

        if not uma:
            self.h_staging_in = self.ctx.enqueue_create_host_buffer[
                DType.uint8
            ](b_cap)
            self.h_staging_toks = self.ctx.enqueue_create_host_buffer[
                DType.uint32
            ](t_cap)
            self.h_staging_bs = self.ctx.enqueue_create_host_buffer[
                DType.uint32
            ](blk_cap)
            self.h_staging_bl = self.ctx.enqueue_create_host_buffer[
                DType.uint32
            ](blk_cap)
            self.h_staging_status = self.ctx.enqueue_create_host_buffer[
                DType.uint32
            ](8)
            self.ctx.synchronize()
        else:
            self.h_staging_in = None
            self.h_staging_toks = None
            self.h_staging_bs = None
            self.h_staging_bl = None
            self.h_staging_status = None

        self.cached_status = Array[UInt32, 8](fill=0)
        self.cached_block_starts = List[UInt32](capacity=blk_cap)
        self.cached_block_starts.resize(unsafe_uninit_length=blk_cap)
        _ = external_call["memset", Int](
            self.cached_block_starts.unsafe_ptr(), Int32(0), blk_cap * 4
        )
        self.cached_block_lens = List[UInt32](capacity=blk_cap)
        self.cached_block_lens.resize(unsafe_uninit_length=blk_cap)
        _ = external_call["memset", Int](
            self.cached_block_lens.unsafe_ptr(), Int32(0), blk_cap * 4
        )
        self.cached_tokens = List[UInt32](capacity=t_cap)
        self.cached_tokens.resize(unsafe_uninit_length=t_cap)
        _ = external_call["memset", Int](
            self.cached_tokens.unsafe_ptr(), Int32(0), t_cap * 4
        )
        self.cached_packed_bytes = List[Byte]()

    def warmup[strict: Bool = True](mut self) raises:
        var sample = "a = 1\n"
        _ = self._run_stage1_gpu[strict](sample.as_bytes())

    def _ensure_input_capacity(mut self, n_bytes: Int) raises:
        var changed = False
        if n_bytes > self.byte_cap:
            var new_cap = align_up(
                max(n_bytes, self.byte_cap * 2), GPU_BYTES_PER_BLOCK
            )
            self.d_input = self.ctx.enqueue_create_buffer[DType.uint8](new_cap)
            self.d_arena = self.ctx.enqueue_create_buffer[DType.uint8](new_cap)
            if not self.has_unified_memory:
                self.h_staging_in = self.ctx.enqueue_create_host_buffer[
                    DType.uint8
                ](new_cap)
            self.byte_cap = new_cap
            changed = True

        var req_blocks = max(1, ceildiv(n_bytes, GPU_BYTES_PER_BLOCK))
        if req_blocks > self.block_cap:
            var new_bcap = max(req_blocks, self.block_cap * 2)
            self.d_thread_fst = self.ctx.enqueue_create_buffer[DType.uint64](
                new_bcap * GPU_BLOCK_THREADS
            )
            self.d_block_lo = self.ctx.enqueue_create_buffer[DType.uint32](
                new_bcap
            )
            self.d_block_hi = self.ctx.enqueue_create_buffer[DType.uint32](
                new_bcap
            )
            self.d_block_state = self.ctx.enqueue_create_buffer[DType.uint8](
                new_bcap
            )
            self.d_block_starts = self.ctx.enqueue_create_buffer[DType.uint32](
                new_bcap
            )
            self.d_block_lens = self.ctx.enqueue_create_buffer[DType.uint32](
                new_bcap
            )
            if not self.has_unified_memory:
                self.h_staging_bs = self.ctx.enqueue_create_host_buffer[
                    DType.uint32
                ](new_bcap)
                self.h_staging_bl = self.ctx.enqueue_create_host_buffer[
                    DType.uint32
                ](new_bcap)
            self.cached_block_starts.reserve(new_bcap)
            self.cached_block_starts.resize(unsafe_uninit_length=new_bcap)
            self.cached_block_lens.reserve(new_bcap)
            self.cached_block_lens.resize(unsafe_uninit_length=new_bcap)
            self.block_cap = new_bcap
            changed = True

        var min_toks = max(16 * 1024, n_bytes // 2)
        if min_toks > self.tok_cap:
            self._grow_token_buffers(min_toks)
            changed = True

        if changed:
            self.ctx.synchronize()

    def _grow_token_buffers(mut self, req_toks: Int) raises:
        var new_tcap = max(req_toks, self.tok_cap * 2)
        self.d_tokens = self.ctx.enqueue_create_buffer[DType.uint32](new_tcap)
        if not self.has_unified_memory:
            self.h_staging_toks = self.ctx.enqueue_create_host_buffer[
                DType.uint32
            ](new_tcap)
        self.cached_tokens.reserve(new_tcap)
        self.cached_tokens.resize(unsafe_uninit_length=new_tcap)
        _ = external_call["memset", Int](
            self.cached_tokens.unsafe_ptr(), Int32(0), new_tcap * 4
        )
        self.tok_cap = new_tcap

    def _run_stage1_gpu[
        strict: Bool
    ](mut self, bytes: Span[Byte, _]) raises -> Int:
        var n_bytes = len(bytes)
        self._ensure_input_capacity(n_bytes)
        var num_blocks = max(1, ceildiv(n_bytes, GPU_BYTES_PER_BLOCK))

        if self.has_unified_memory:
            # Unified Memory fast path (Apple M1/M2/M3/M4): 28.5 GB/s write-combined store directly to GPU buffer!
            _ = external_call["memcpy", Int](
                self.d_input.unsafe_host_ptr(), bytes.unsafe_ptr(), n_bytes
            )

        while True:
            var t_in = TileTensor(self.d_input, row_major((self.byte_cap,)))
            var t_tfst = TileTensor(
                self.d_thread_fst,
                row_major((self.block_cap * GPU_BLOCK_THREADS,)),
            )
            var t_blo = TileTensor(
                self.d_block_lo, row_major((self.block_cap,))
            )
            var t_bhi = TileTensor(
                self.d_block_hi, row_major((self.block_cap,))
            )
            var t_bst = TileTensor(
                self.d_block_state, row_major((self.block_cap,))
            )
            var t_bstarts = TileTensor(
                self.d_block_starts, row_major((self.block_cap,))
            )
            var t_blens = TileTensor(
                self.d_block_lens, row_major((self.block_cap,))
            )
            var t_tokens = TileTensor(self.d_tokens, row_major((self.tok_cap,)))
            var t_status = TileTensor(self.d_status, row_major((8,)))

            comptime k_init = init_status_kernel[type_of(t_status.layout)]
            comptime k_fst = fst_and_utf8_kernel[
                strict,
                type_of(t_in.layout),
                type_of(t_tfst.layout),
                type_of(t_blo.layout),
                type_of(t_status.layout),
            ]
            comptime k_scan = scan_block_states_kernel[
                type_of(t_blo.layout),
                type_of(t_bst.layout),
                type_of(t_status.layout),
            ]
            comptime k_tok = tokenize_compact_kernel[
                strict,
                type_of(t_in.layout),
                type_of(t_tfst.layout),
                type_of(t_bst.layout),
                type_of(t_bstarts.layout),
                type_of(t_tokens.layout),
                type_of(t_status.layout),
            ]

            if not self.has_unified_memory:
                if case .Some(ref h_in) = self.h_staging_in:
                    _ = external_call["memcpy", Int](
                        h_in.unsafe_ptr(), bytes.unsafe_ptr(), n_bytes
                    )
                    var copy_b = min(self.byte_cap, align_up(n_bytes, 64))
                    self.ctx.enqueue_copy(
                        dst_buf=self.d_input.create_sub_buffer[DType.uint8](
                            0, copy_b
                        ),
                        src_buf=h_in.create_sub_buffer[DType.uint8](0, copy_b),
                    )

            self.ctx.enqueue_function[k_init](
                t_status, grid_dim=1, block_dim=32
            )
            self.ctx.enqueue_function[k_fst](
                t_in.as_imm(),
                t_tfst,
                t_blo,
                t_bhi,
                t_status,
                UInt32(n_bytes),
                grid_dim=num_blocks,
                block_dim=GPU_BLOCK_THREADS,
            )
            self.ctx.enqueue_function[k_scan](
                t_blo.as_imm(),
                t_bhi.as_imm(),
                t_bst,
                t_status,
                UInt32(num_blocks),
                grid_dim=1,
                block_dim=GPU_BLOCK_THREADS,
            )
            self.ctx.enqueue_function[k_tok](
                t_in.as_imm(),
                t_tfst.as_imm(),
                t_bst.as_imm(),
                t_bstarts,
                t_blens,
                t_tokens,
                t_status,
                UInt32(n_bytes),
                UInt32(self.tok_cap),
                grid_dim=num_blocks,
                block_dim=GPU_BLOCK_THREADS,
            )

            if self.has_unified_memory:
                # Single command-buffer sync; read exact `total_toks` afterwards!
                self.ctx.synchronize()
                var st_ptr = self.d_status.unsafe_host_ptr()
                if st_ptr[unsafe_offset=STATUS_OVERFLOW] != 0:
                    var needed = (
                        Int(st_ptr[unsafe_offset=STATUS_TOK_COUNT]) + 1024
                    )
                    self._grow_token_buffers(max(needed, n_bytes))
                    self.ctx.synchronize()
                    continue
                if (
                    st_ptr[unsafe_offset=STATUS_UTF8_ERR] != 0
                    or st_ptr[unsafe_offset=STATUS_LEX_ERR] != 0
                ):
                    return -1

                var total_toks = Int(st_ptr[unsafe_offset=STATUS_TOK_COUNT])
                _ = external_call["memcpy", Int](
                    self.cached_block_starts.unsafe_ptr(),
                    self.d_block_starts.unsafe_host_ptr(),
                    num_blocks * 4,
                )
                _ = external_call["memcpy", Int](
                    self.cached_block_lens.unsafe_ptr(),
                    self.d_block_lens.unsafe_host_ptr(),
                    num_blocks * 4,
                )
                if total_toks > 0:
                    _ = external_call["memcpy", Int](
                        self.cached_tokens.unsafe_ptr(),
                        self.d_tokens.unsafe_host_ptr(),
                        total_toks * 4,
                    )
                return num_blocks
            else:
                var est_toks = min(self.tok_cap, max(64, n_bytes))
                __guard case .Some(ref h_st) = self.h_staging_status else:
                    return -1
                __guard case .Some(ref h_bs) = self.h_staging_bs else:
                    return -1
                __guard case .Some(ref h_bl) = self.h_staging_bl else:
                    return -1
                __guard case .Some(ref h_tk) = self.h_staging_toks else:
                    return -1
                self.ctx.enqueue_copy(dst_buf=h_st, src_buf=self.d_status)
                self.ctx.enqueue_copy(
                    dst_buf=h_bs.create_sub_buffer[DType.uint32](0, num_blocks),
                    src_buf=self.d_block_starts.create_sub_buffer[DType.uint32](
                        0, num_blocks
                    ),
                )
                self.ctx.enqueue_copy(
                    dst_buf=h_bl.create_sub_buffer[DType.uint32](0, num_blocks),
                    src_buf=self.d_block_lens.create_sub_buffer[DType.uint32](
                        0, num_blocks
                    ),
                )
                self.ctx.enqueue_copy(
                    dst_buf=h_tk.create_sub_buffer[DType.uint32](0, est_toks),
                    src_buf=self.d_tokens.create_sub_buffer[DType.uint32](
                        0, est_toks
                    ),
                )
                self.ctx.synchronize()

                if h_st[STATUS_OVERFLOW] != 0:
                    var needed = Int(h_st[STATUS_TOK_COUNT]) + 1024
                    self._grow_token_buffers(max(needed, n_bytes))
                    self.ctx.synchronize()
                    continue
                if h_st[STATUS_UTF8_ERR] != 0 or h_st[STATUS_LEX_ERR] != 0:
                    return -1
                var total_toks = Int(h_st[STATUS_TOK_COUNT])
                if total_toks > est_toks:
                    self.ctx.enqueue_copy(
                        dst_buf=h_tk.create_sub_buffer[DType.uint32](
                            0, total_toks
                        ),
                        src_buf=self.d_tokens.create_sub_buffer[DType.uint32](
                            0, total_toks
                        ),
                    )
                    self.ctx.synchronize()
                _ = external_call["memcpy", Int](
                    self.cached_block_starts.unsafe_ptr(),
                    h_bs.unsafe_ptr(),
                    num_blocks * 4,
                )
                _ = external_call["memcpy", Int](
                    self.cached_block_lens.unsafe_ptr(),
                    h_bl.unsafe_ptr(),
                    num_blocks * 4,
                )
                if total_toks > 0:
                    _ = external_call["memcpy", Int](
                        self.cached_tokens.unsafe_ptr(),
                        h_tk.unsafe_ptr(),
                        total_toks * 4,
                    )
                return num_blocks

    def _parse_tape_gpu[
        strict: Bool
    ](mut self, bytes: Span[Byte, _], force_gpu: Bool) raises -> Result[
        _ParsedTape
    ]:
        var n = len(bytes)
        if n > MAX_DOCUMENT_BYTES:
            return .Err(
                Error(
                    "TOML parse error at 1:1: TOML document exceeds maximum"
                    " size (2 GiB)."
                )
            )
        if n == 0 or (not force_gpu and n < self.min_gpu_bytes):
            return _parse_tape[strict](bytes)

        var num_blocks = self._run_stage1_gpu[strict](bytes)
        if num_blocks < 0:
            return _parse_tape[strict](bytes)

        var cur = _CachedBlockCursor(
            self.cached_block_starts.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin](),
            self.cached_block_lens.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin](),
            self.cached_tokens.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin](),
            0,
            num_blocks,
        )
        var builder = _Stage2Builder[strict, bytes.origin](bytes, cur^)
        if not builder.parse_document():
            return .Err(builder.format_error())
        return .Ok(builder^.into_tape())

    def _materialize_gpu(
        mut self,
        bytes: Span[Byte, _],
        var tape: _ParsedTape,
        force_gpu: Bool,
    ) raises -> TomlDocument[Mode.Eager, ImmUntrackedOrigin]:
        var n_nodes = len(tape.nodes)
        var src_len = len(bytes)
        if src_len == 0 or (
            not force_gpu and n_nodes < DEFAULT_MIN_GPU_EAGER_NODES
        ):
            return _materialize(bytes, tape^)

        var nodes, key_index, array_slots = tape^.into_parts()
        var req_words = n_nodes * 8
        if req_words > self.node_word_cap:
            var new_nw = max(req_words, self.node_word_cap * 2)
            self.d_node_words = self.ctx.enqueue_create_buffer[DType.uint32](
                new_nw
            )
            self.node_word_cap = new_nw
            self.ctx.synchronize()

        self._ensure_input_capacity(src_len)

        var t_src = TileTensor(self.d_input, row_major((self.byte_cap,)))
        var t_arena = TileTensor(self.d_arena, row_major((self.byte_cap,)))
        var t_nw = TileTensor(
            self.d_node_words, row_major((self.node_word_cap,))
        )
        comptime k_mat = materialize_eager_nodes_kernel[
            type_of(t_src.layout),
            type_of(t_arena.layout),
            type_of(t_nw.layout),
        ]

        var arena = List[Byte](capacity=src_len)
        arena.resize(unsafe_uninit_length=src_len)

        if self.has_unified_memory:
            _ = external_call["memcpy", Int](
                self.d_input.unsafe_host_ptr(), bytes.unsafe_ptr(), src_len
            )
            _ = external_call["memcpy", Int](
                self.d_arena.unsafe_host_ptr(), bytes.unsafe_ptr(), src_len
            )
            _ = external_call["memcpy", Int](
                self.d_node_words.unsafe_host_ptr(),
                nodes.unsafe_ptr(),
                n_nodes * 32,
            )
            self.ctx.enqueue_function[k_mat](
                t_src.as_imm(),
                t_arena,
                t_nw,
                UInt32(n_nodes),
                grid_dim=ceildiv(n_nodes, GPU_BLOCK_THREADS),
                block_dim=GPU_BLOCK_THREADS,
            )
            self.ctx.synchronize()
            _ = external_call["memcpy", Int](
                arena.unsafe_ptr(), self.d_arena.unsafe_host_ptr(), src_len
            )
            _ = external_call["memcpy", Int](
                nodes.unsafe_ptr(),
                self.d_node_words.unsafe_host_ptr(),
                n_nodes * 32,
            )
        else:
            var d_in_sub = self.d_input.create_sub_buffer[DType.uint8](
                0, src_len
            )
            var d_ar_sub = self.d_arena.create_sub_buffer[DType.uint8](
                0, src_len
            )
            var d_nw_sub = self.d_node_words.create_sub_buffer[DType.uint32](
                0, req_words
            )
            var nodes_u32_ptr = nodes.unsafe_ptr().unsafe_bitcast[UInt32]()
            self.ctx.enqueue_copy(
                dst_buf=d_in_sub,
                src_ptr=bytes.unsafe_ptr().unsafe_mut_cast[False](),
            )
            self.ctx.enqueue_copy(dst_buf=d_ar_sub, src_buf=d_in_sub)
            self.ctx.enqueue_copy(
                dst_buf=d_nw_sub,
                src_ptr=nodes_u32_ptr.unsafe_mut_cast[False](),
            )
            self.ctx.enqueue_function[k_mat](
                t_src.as_imm(),
                t_arena,
                t_nw,
                UInt32(n_nodes),
                grid_dim=ceildiv(n_nodes, GPU_BLOCK_THREADS),
                block_dim=GPU_BLOCK_THREADS,
            )
            self.ctx.enqueue_copy(dst_ptr=arena.unsafe_ptr(), src_buf=d_ar_sub)
            self.ctx.enqueue_copy(dst_ptr=nodes_u32_ptr, src_buf=d_nw_sub)
            self.ctx.synchronize()

        var temporals = List[DateTime]()
        var n_ptr = nodes.unsafe_ptr()
        var src_ptr = bytes.unsafe_ptr()
        for i in range(n_nodes):
            ref node = n_ptr[unsafe_offset=i]
            match node.kind:
                case .Float:
                    var raw_b = Span[Byte, bytes.origin](
                        unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                        length=Int(node.len),
                    )
                    var u = bitcast[DType.uint64, 1](
                        decode_float_unchecked(raw_b, node.flags)
                    )
                    node.start = UInt32(u & 0xFFFFFFFF)
                    node.len = UInt32(u >> 32)
                case .Time:
                    var raw_b = Span[Byte, bytes.origin](
                        unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                        length=Int(node.len),
                    )
                    var idx = UInt32(len(temporals))
                    temporals.append(
                        DateTime(
                            Date(year=0, month=0, day=0),
                            decode_time_unchecked(raw_b),
                            Offset(),
                            True,
                        )
                    )
                    node.start = idx
                case .DateTime:
                    var raw_b = Span[Byte, bytes.origin](
                        unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                        length=Int(node.len),
                    )
                    var idx = UInt32(len(temporals))
                    temporals.append(decode_datetime_unchecked(raw_b))
                    node.start = idx
                case .Array:
                    if (node.flags & NodeFlags.CONTIGUOUS) == 0 and (
                        node.flags & NodeFlags.SLOTTED
                    ) == 0:
                        var slot_start = UInt32(len(array_slots))
                        var curr = node.first_child
                        while curr != NO_NODE:
                            array_slots.append(curr)
                            curr = n_ptr[unsafe_offset=Int(curr)].next_sibling
                        node.start = slot_start
                        node.flags |= NodeFlags.SLOTTED
                case _:
                    pass

        var slots_ptr = key_index.slots.unsafe_ptr()
        var cap = len(key_index.slots)
        for s_idx in range(cap):
            ref slot = slots_ptr[unsafe_offset=s_idx]
            if (
                not slot.is_empty()
                and (slot.key_len_flags & KEY_ESCAPE_BIT) != 0
            ):
                slot.key_len_flags = n_ptr[
                    unsafe_offset=Int(slot.node_idx)
                ].key_len

        var store = _Store(key_index^, arena^, array_slots^, temporals^)
        return TomlDocument[Mode.Eager, ImmUntrackedOrigin](
            Span[Byte, ImmUntrackedOrigin](), nodes^, store^, 0
        )

    def try_parse[
        mode: Mode = Mode.Strict
    ](
        mut self,
        data: StringSpan,
        *,
        force_gpu: Bool = False,
    ) raises -> Result[
        TomlDocument[mode, data.origin]
    ] where (mode != Mode.Eager):
        comptime strict = mode != Mode.Trusted
        var bytes = data.as_bytes()
        var tape_res = self._parse_tape_gpu[strict](bytes, force_gpu)
        if case .Err(_) = tape_res:
            return .Err(tape_res^.unsafe_take_error())
        var nodes, key_index, array_slots = (
            tape_res^.unsafe_take_value().into_parts()
        )
        return .Ok(
            TomlDocument[mode, data.origin](
                bytes, nodes^, _Store(key_index^, array_slots^), 0
            )
        )

    def try_parse[
        mode: Mode
    ](
        mut self,
        data: StringSpan,
        *,
        force_gpu: Bool = False,
        gpu_materialize: Bool = False,
    ) raises -> Result[TomlDocument[Mode.Eager, ImmUntrackedOrigin]] where (
        mode == Mode.Eager
    ):
        var bytes = data.as_bytes()
        var tape_res = self._parse_tape_gpu[True](bytes, force_gpu)
        if case .Err(_) = tape_res:
            return .Err(tape_res^.unsafe_take_error())
        if gpu_materialize:
            return .Ok(
                self._materialize_gpu(
                    bytes, tape_res^.unsafe_take_value(), force_gpu
                )
            )
        return .Ok(_materialize(bytes, tape_res^.unsafe_take_value()))

    def parse[
        mode: Mode = Mode.Strict
    ](
        mut self,
        data: StringSpan,
        *,
        force_gpu: Bool = False,
    ) raises -> TomlDocument[mode, data.origin] where (mode != Mode.Eager):
        return self.try_parse[mode](data, force_gpu=force_gpu).take()

    def parse[
        mode: Mode
    ](
        mut self,
        data: StringSpan,
        *,
        force_gpu: Bool = False,
        gpu_materialize: Bool = False,
    ) raises -> TomlDocument[Mode.Eager, ImmUntrackedOrigin] where (
        mode == Mode.Eager
    ):
        return self.try_parse[Mode.Eager](
            data, force_gpu=force_gpu, gpu_materialize=gpu_materialize
        ).take()

    def parse_file[
        mode: Mode = Mode.Strict
    ](
        mut self,
        path: StringSpan,
        *,
        force_gpu: Bool = False,
    ) raises -> TomlFile[mode]:
        var mapped_file = MappedFile(path)
        var raw_bytes = mapped_file.bytes()
        comptime if case .Eager = mode:
            var res = self._parse_tape_gpu[True](raw_bytes, force_gpu)
            if case .Err(_) = res:
                raise res^.unsafe_take_error()
            var doc = _materialize(raw_bytes, res^.unsafe_take_value())
            _ = mapped_file^
            return TomlFile[mode](
                rebind_var[TomlDocument[mode, ImmUntrackedOrigin]](doc^),
                Optional[MappedFile](None),
            )
        else:
            comptime strict = mode != Mode.Trusted
            var res = self._parse_tape_gpu[strict](raw_bytes, force_gpu)
            if case .Err(_) = res:
                raise res^.unsafe_take_error()
            var nodes, key_index, array_slots = (
                res^.unsafe_take_value().into_parts()
            )
            var untracked_bytes = Span[Byte, ImmUntrackedOrigin](
                unsafe_ptr=raw_bytes.unsafe_ptr()
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[ImmUntrackedOrigin](),
                length=len(raw_bytes),
            )
            var doc = TomlDocument[mode, ImmUntrackedOrigin](
                untracked_bytes, nodes^, _Store(key_index^, array_slots^), 0
            )
            return TomlFile[mode](doc^, Optional(mapped_file^))

    def parse_batch_eager(
        mut self,
        docs: Span[String, _],
        *,
        force_gpu: Bool = True,
    ) raises -> List[TomlDocument[Mode.Eager, ImmUntrackedOrigin]]:
        """Parse a batch of independent TOML documents in a SINGLE GPU Stage-1 launch.
        """
        var n_docs = len(docs)
        var out = List[TomlDocument[Mode.Eager, ImmUntrackedOrigin]](
            capacity=n_docs
        )
        if n_docs == 0:
            return out^

        var doc_starts = List[Int](capacity=n_docs)
        var doc_lens = List[Int](capacity=n_docs)
        var total_packed = 0
        for i in range(n_docs):
            var blen = docs[i].byte_length()
            doc_starts.append(total_packed)
            doc_lens.append(blen)
            total_packed += max(
                GPU_BYTES_PER_BLOCK, align_up(blen, GPU_BYTES_PER_BLOCK)
            )

        if not force_gpu and total_packed < self.min_gpu_bytes:
            for i in range(n_docs):
                var sb = docs[i].as_bytes()
                var tr = _parse_tape[True](sb)
                if case .Err(_) = tr:
                    raise tr^.unsafe_take_error()
                out.append(_materialize(sb, tr^.unsafe_take_value()))
            return out^

        self.cached_packed_bytes.reserve(total_packed)
        self.cached_packed_bytes.resize(unsafe_uninit_length=total_packed)
        var c_base = self.cached_packed_bytes.unsafe_ptr()

        for i in range(n_docs):
            var off = doc_starts[i]
            var blen = doc_lens[i]
            var slot_end = doc_starts[i + 1] if i + 1 < n_docs else total_packed
            if blen > 0:
                unsafe_memcpy(
                    dest=c_base.unsafe_offset(off),
                    src=docs[i].as_bytes().unsafe_ptr(),
                    count=blen,
                )
            for p in range(off + blen, slot_end):
                c_base[unsafe_offset=p] = UInt8(ord("\n"))

        var packed_input = Span[Byte, ImmUntrackedOrigin](
            unsafe_ptr=self.cached_packed_bytes.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin](),
            length=total_packed,
        )

        var num_blocks = self._run_stage1_gpu[True](packed_input)
        if num_blocks < 0:
            for i in range(n_docs):
                var sb = docs[i].as_bytes()
                var tr = _parse_tape[True](sb)
                if case .Err(_) = tr:
                    raise tr^.unsafe_take_error()
                out.append(_materialize(sb, tr^.unsafe_take_value()))
            return out^

        var packed_span = Span[Byte, ImmUntrackedOrigin](
            unsafe_ptr=self.cached_packed_bytes.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin](),
            length=total_packed,
        )
        var bs_ptr = (
            self.cached_block_starts.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin]()
        )
        var bl_ptr = (
            self.cached_block_lens.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin]()
        )
        var toks_ptr = (
            self.cached_tokens.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin]()
        )

        for i in range(n_docs):
            var off = doc_starts[i]
            var blen = doc_lens[i]
            var sb = docs[i].as_bytes()
            if blen == 0:
                var tr = _parse_tape[True](sb)
                out.append(_materialize(sb, tr^.unsafe_take_value()))
                continue
            var b_start = off // GPU_BYTES_PER_BLOCK
            var b_end = ceildiv(off + blen, GPU_BYTES_PER_BLOCK)
            var cur = _CachedBlockCursor(
                bs_ptr, bl_ptr, toks_ptr, b_start, b_end
            )
            var builder = _Stage2Builder[True, ImmUntrackedOrigin](
                packed_span, cur^, off, off + blen
            )
            if not builder.parse_document():
                raise builder.format_error()
            out.append(_materialize(sb, builder^.into_tape()))

        return out^


def parse_toml_gpu[
    mode: Mode = Mode.Strict
](data: StringSpan, *, force_gpu: Bool = False) raises -> TomlDocument[
    mode, data.origin
] where (mode != Mode.Eager):
    var parser = GpuTomlParser(
        initial_capacity_bytes=max(65536, data.byte_length())
    )
    return parser.parse[mode](data, force_gpu=force_gpu)


def parse_toml_gpu[
    mode: Mode
](data: StringSpan, *, force_gpu: Bool = False) raises -> TomlDocument[
    Mode.Eager, ImmUntrackedOrigin
] where (mode == Mode.Eager):
    var parser = GpuTomlParser(
        initial_capacity_bytes=max(65536, data.byte_length())
    )
    return parser.parse[Mode.Eager](data, force_gpu=force_gpu)


def toml_to_tagged_json_gpu[
    mode: Mode = Mode.Strict
](
    mut parser: GpuTomlParser, content: StringSpan, *, force_gpu: Bool = True
) raises -> String:
    var out = String()
    comptime if mode == Mode.Eager:
        var doc = parser.parse[Mode.Eager](content, force_gpu=force_gpu)
        doc.to_json(out)
    else:
        var doc = parser.parse[mode](content, force_gpu=force_gpu)
        doc.to_json(out)
    return out^
