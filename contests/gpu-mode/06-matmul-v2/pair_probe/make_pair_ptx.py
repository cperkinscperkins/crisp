"""Endeavour 214 step 1: hand-edit v7's PTX (v7.ptx) into a cta_group::2 kernel (pair.ptx).

Pair = CTAs (2i, 2i+1) along x (= output row tiles), same column tile.  Rank 0 leads.
Every replacement asserts its match count so a drift in the generated PTX fails loudly."""
import sys

src = open("v7.ptx").read()


def rep(old, new, count=1):
    global src
    n = src.count(old)
    if n != count:
        sys.exit(f"expected {count} x {old!r}, found {n}")
    src = src.replace(old, new)


# --- cluster shape + rank registers -------------------------------------------------------------
rep(")                                       // @matmul\n{\n",
    ")                                       // @matmul\n.reqnctapercluster 2, 1, 1\n{\n"
    "\t.reg .b32 \t%q<16>;\n\t.reg .b64 \t%qd<16>;\n\t.reg .pred \t%qp<4>;\n\t.reg .b16 \t%qh<2>;\n")
rep("\tmov.u32 \t%r1, %tid.x;\n",
    "\tmov.u32 \t%r1, %tid.x;\n"
    "\tmov.u32 \t%q0, %cluster_ctarank;\n"
    "\tsetp.ne.b32 \t%qp0, %q0, 0;\n"          # qp0: this CTA is the peer (not the leader)
    "\tsetp.eq.b32 \t%qp1, %q0, 0;\n"          # qp1: this CTA is the leader
    "\tmov.b16 \t%qh0, 3;\n"                   # multicast mask: both CTAs of the pair
    "\tshl.b32 \t%q1, %q0, 7;\n")              # this CTA's B column offset: 128 * rank

# --- tensor memory: pair-wide alloc / relinquish / dealloc --------------------------------------
rep("tcgen05.alloc.cta_group::1.sync.aligned.shared::cta.b32",
    "tcgen05.alloc.cta_group::2.sync.aligned.shared::cta.b32")
rep("tcgen05.relinquish_alloc_permit.cta_group::1.sync.aligned;",
    "tcgen05.relinquish_alloc_permit.cta_group::2.sync.aligned;")
rep("tcgen05.dealloc.cta_group::1.sync.aligned.b32 %r795, 256;",
    "tcgen05.dealloc.cta_group::2.sync.aligned.b32 %r795, 256;")

# --- barrier counts: full = 2 loads x 2 CTAs; acc-empty = 4 epilogue warps x 2 CTAs --------------
rep("\tmov.b32 \t%r314, 2;\n", "\tmov.b32 \t%r314, 4;\n")
rep("\tmov.b32 \t%r316, 4;\n", "\tmov.b32 \t%r316, 8;\n")

# --- entry: barrier inits visible cluster-wide, pair's tensor memory allocated, before any use ---
rep("$L__BB57_10:                            // %tma_mbar_cont113\n\tbar.sync \t0;\n",
    "$L__BB57_10:                            // %tma_mbar_cont113\n\tbar.sync \t0;\n"
    "\tfence.mbarrier_init.release.cluster;\n"
    "\tbarrier.cluster.arrive.release.aligned;\n"
    "\tbarrier.cluster.wait.acquire.aligned;\n")

# --- exit: neither CTA tears down while the pair can still use its memory ------------------------
rep("$L__BB57_38:                            // %dt_exit\n"
    "\tsetp.lt.u32 \t%p39, %r4, 32;\n"
    "\t// begin inline asm\n\ttcgen05.fence::before_thread_sync;\n\t// end inline asm\n"
    "\tbar.sync \t0;\n",
    "$L__BB57_38:                            // %dt_exit\n"
    "\tsetp.lt.u32 \t%p39, %r4, 32;\n"
    "\t// begin inline asm\n\ttcgen05.fence::before_thread_sync;\n\t// end inline asm\n"
    "\tbar.sync \t0;\n"
    "\tbarrier.cluster.arrive.release.aligned;\n"
    "\tbarrier.cluster.wait.acquire.aligned;\n")

# --- producer: A + this CTA's half of B, all completing on the LEADER's full[slot] ---------------
TMA = "cp.async.bulk.tensor.2d.shared::cluster.global.tile.mbarrier::complete_tx::bytes"
TMA2 = "cp.async.bulk.tensor.2d.cta_group::2.shared::cluster.global.tile.mbarrier::complete_tx::bytes"
old_issue = f"""	cvt.u32.u64 	%r384, %rd99;
	mov.b32 	%r385, 16384;
	// begin inline asm
	mbarrier.arrive.expect_tx.shared::cta.b64 _, [%r384], %r385;
	// end inline asm
	cvta.shared.u64 	%rd102, %rd101;
	cvta.to.shared::cluster.u64 	%rd103, %rd102;
	{TMA} [%rd103], [%rd1, {{%r389, %r21}}], [%rd99];
	shl.b64 	%rd104, %rd96, 15;
	add.s64 	%rd105, %rd3, %rd104;
	mov.b32 	%r387, 32768;
	// begin inline asm
	mbarrier.arrive.expect_tx.shared::cta.b64 _, [%r384], %r387;
	// end inline asm
	cvta.shared.u64 	%rd106, %rd105;
	cvta.to.shared::cluster.u64 	%rd107, %rd106;
	{TMA} [%rd107], [%rd2, {{%r291, %r389}}], [%rd99];
	add.s64 	%rd108, %rd105, 8192;
	cvta.shared.u64 	%rd109, %rd108;
	cvta.to.shared::cluster.u64 	%rd110, %rd109;
	{TMA} [%rd110], [%rd2, {{%r292, %r389}}], [%rd99];
	add.s64 	%rd111, %rd105, 16384;
	cvta.shared.u64 	%rd112, %rd111;
	cvta.to.shared::cluster.u64 	%rd113, %rd112;
	{TMA} [%rd113], [%rd2, {{%r293, %r389}}], [%rd99];
	add.s64 	%rd114, %rd105, 24576;
	cvta.shared.u64 	%rd115, %rd114;
	cvta.to.shared::cluster.u64 	%rd116, %rd115;
	{TMA} [%rd116], [%rd2, {{%r294, %r389}}], [%rd99];
"""
new_issue = f"""	mapa.shared::cluster.u64 	%qd1, %rd99, 0;
	mbarrier.arrive.expect_tx.release.cluster.shared::cluster.b64 _, [%qd1], 16384;
	cvta.shared.u64 	%rd102, %rd101;
	cvta.to.shared::cluster.u64 	%rd103, %rd102;
	{TMA2} [%rd103], [%rd1, {{%r389, %r21}}], [%qd1];
	shl.b64 	%rd104, %rd96, 15;
	add.s64 	%rd105, %rd3, %rd104;
	mbarrier.arrive.expect_tx.release.cluster.shared::cluster.b64 _, [%qd1], 16384;
	add.s32 	%q2, %r291, %q1;
	add.s32 	%q3, %q2, 64;
	cvta.shared.u64 	%rd106, %rd105;
	cvta.to.shared::cluster.u64 	%rd107, %rd106;
	{TMA2} [%rd107], [%rd2, {{%q2, %r389}}], [%qd1];
	add.s64 	%rd108, %rd105, 8192;
	cvta.shared.u64 	%rd109, %rd108;
	cvta.to.shared::cluster.u64 	%rd110, %rd109;
	{TMA2} [%rd110], [%rd2, {{%q3, %r389}}], [%qd1];
"""
rep(old_issue, new_issue)

# --- MMA warp: only the leader waits on full and issues; M = 256 --------------------------------
rep("""	and.b32 	%r340, %r337, 1;
$L__BB57_31:""", """	and.b32 	%r340, %r337, 1;
	@%qp0 bra 	$Q_SKIPW;
$L__BB57_31:""")
rep("""	setp.ne.b32 	%p19, %r4, 160;
	mov.b32 	%r348, 1;""", """$Q_SKIPW:
	setp.ne.or.b32 	%p19, %r4, 160, %qp0;
	mov.b32 	%r348, 1;""")
rep("\tmov.b32 \t%r344, 138477584;\n", "\tmov.b32 \t%r344, 272695312;\n")   # M>>4 = 16 at bit 24
rep("tcgen05.mma.cta_group::1.kind::f16", "tcgen05.mma.cta_group::2.kind::f16", 4)
# empty[slot]: one commit frees the slot in BOTH CTAs
rep("tcgen05.commit.cta_group::1.mbarrier::arrive::one.shared::cluster.b64 [%r355];",
    "tcgen05.commit.cta_group::2.mbarrier::arrive::one.shared::cluster.multicast::cluster.b64 [%r355], %qh0;")
# acc-full: leader only, signals both CTAs' epilogues
rep("\tsetp.eq.b32 \t%p22, %r4, 160;\n", "\tsetp.eq.and.b32 \t%p22, %r4, 160, %qp1;\n")
rep("tcgen05.commit.cta_group::1.mbarrier::arrive::one.shared::cluster.b64 [%r373];",
    "tcgen05.commit.cta_group::2.mbarrier::arrive::one.shared::cluster.multicast::cluster.b64 [%r373], %qh0;")

# --- epilogue: acc-empty arrives on the LEADER's barrier ----------------------------------------
rep("\tmbarrier.arrive.shared.b64 \t%rd155, [__crisp_mbar_4];\n",
    "\tmov.b64 \t%qd2, __crisp_mbar_4;\n"
    "\tmapa.shared::cluster.u64 \t%qd3, %qd2, 0;\n"
    "\tmbarrier.arrive.release.cluster.shared::cluster.b64 _, [%qd3];\n")

assert "cta_group::1" not in src.split(".entry matmul")[1], "a cta_group::1 survived"
open("pair.ptx", "w", newline="\n").write(src)
print("wrote pair.ptx")
