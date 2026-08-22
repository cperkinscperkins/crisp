/*
 * Chapter 6 (Endeavor 150) — oneDNN WHEN IT CANNOT FUSE.
 *
 * dnnl::matmul with NO post-op, followed by a SEPARATE kernel applying the chapter's custom
 * activation.  This is the point of chapter 6, measured rather than argued:
 *
 *   chap5  oneDNN fuses relu via a post-op — one kernel, no round trip.  Crisp's real rival.
 *   chap6  the activation is a QUADRATIC TAIL (x > 0.5 ? x : x*x*0.01).  oneDNN's post-ops are
 *          a FIXED SET of eltwise primitives and that is not one of them, so even the library
 *          that CAN fuse has to fall back to a second kernel and a full HBM round trip of C.
 *          Crisp pays nothing, because its epilogue is just a function the user wrote.
 *
 * So chapter 5 asks "can Crisp keep up with a library on the library's own turf?" and chapter 6
 * asks "what happens the moment you step off that turf?".  Only the pair is meaningful.
 *
 * WHAT IS TIMED: matmul start -> activation end, including the inter-launch gap, since that gap
 * is part of what fusion removes.  matmul_median_us reports the GEMM alone so the round-trip
 * cost is visible directly rather than inferred.
 *
 * A = B = 1 so every C == K; the activation is the IDENTITY above 0.5, so C == K survives and
 * the correctness gate stays exact (see the chapter-6 Crisp kernel for why that matters).
 *
 * Build: icpx -fsycl -O3 ... onednn_optimal.cpp -ldnnl -o onednn_optimal
 */
#include <sycl/sycl.hpp>
#include <oneapi/dnnl/dnnl.hpp>
#include <oneapi/dnnl/dnnl_sycl.hpp>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <unordered_map>
#include <vector>
#include <chrono>

using namespace dnnl;

int main(int argc, char** argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M      = argc > 1 ? atoi(argv[1]) : 256;
    int N      = argc > 2 ? atoi(argv[2]) : 256;
    int K      = argc > 3 ? atoi(argv[3]) : 256;
    int warmup = argc > 4 ? atoi(argv[4]) : 20;
    int iters  = argc > 5 ? atoi(argv[5]) : 100;

    sycl::queue q{sycl::gpu_selector_v, sycl::property::queue::enable_profiling{}};

    float* A = sycl::malloc_device<float>((size_t)M * K, q);
    float* B = sycl::malloc_device<float>((size_t)K * N, q);
    float* C = sycl::malloc_device<float>((size_t)M * N, q);
    std::vector<float> h_A((size_t)M * K, 1.0f), h_B((size_t)K * N, 1.0f), h_C((size_t)M * N, 0.0f);
    q.memcpy(A, h_A.data(), h_A.size() * 4).wait();
    q.memcpy(B, h_B.data(), h_B.size() * 4).wait();
    q.memcpy(C, h_C.data(), h_C.size() * 4).wait();

    engine eng = sycl_interop::make_engine(q.get_device(), q.get_context());
    stream  strm = sycl_interop::make_stream(eng, q);

    using dt = memory::data_type;
    using tag = memory::format_tag;
    auto a_md = memory::desc({M, K}, dt::f32, tag::ab);
    auto b_md = memory::desc({K, N}, dt::f32, tag::ab);
    auto c_md = memory::desc({M, N}, dt::f32, tag::ab);

    primitive_attr attr;
#ifdef FAST_MATH
    // Match the tf32 tensor-core math the Crisp kernel and oneMKL's float_to_tf32 use, so the
    // comparison is tf32-vs-tf32 rather than tf32-vs-fp32.
    attr.set_fpmath_mode(fpmath_mode::tf32);
#endif
    // NO post-op: oneDNN has no eltwise primitive for a quadratic tail, so the activation
    // cannot ride inside the matmul and must become its own pass over C.

    auto pd = matmul::primitive_desc(eng, a_md, b_md, c_md, attr);
    auto prim = matmul(pd);

    memory a_mem(a_md, eng, A), b_mem(b_md, eng, B), c_mem(c_md, eng, C);
    std::unordered_map<int, memory> args = {
        {DNNL_ARG_SRC, a_mem}, {DNNL_ARG_WEIGHTS, b_mem}, {DNNL_ARG_DST, c_mem}};

    const size_t total = (size_t)M * N;
    // The activation as its OWN kernel — the cost fusion removes.  Explicit depends_on rather
    // than queue ordering: the queue is out-of-order, and without the dependency this could be
    // scheduled against a half-written C.
    auto act_launch = [&](sycl::event dep) {
        return q.submit([&](sycl::handler& h) {
            h.depends_on(dep);
            h.parallel_for(sycl::range<1>(total), [=](sycl::id<1> i) {
                float v = C[i];
                C[i] = v > 0.5f ? v : v * v * 0.01f;
            });
        });
    };

    for (int i = 0; i < warmup; i++) {
        auto e1 = sycl_interop::execute(prim, strm, args);
        act_launch(e1).wait();
    }

    std::vector<double> kt(iters), gt(iters);
    for (int i = 0; i < iters; i++) {
        auto e1 = sycl_interop::execute(prim, strm, args);
        auto e2 = act_launch(e1);
        e2.wait();
        auto g0 = e1.get_profiling_info<sycl::info::event_profiling::command_start>();
        auto g1 = e1.get_profiling_info<sycl::info::event_profiling::command_end>();
        auto a1 = e2.get_profiling_info<sycl::info::event_profiling::command_end>();
        kt[i] = (double)(a1 - g0) / 1000.0;   // matmul + gap + activation
        gt[i] = (double)(g1 - g0) / 1000.0;   // matmul alone
    }

    q.memcpy(h_C.data(), C, h_C.size() * 4).wait();
    double expected = (double)K, maxerr = 0.0;      // A=B=1 => C == K, and the activation is identity above 0.5
    for (size_t i = 0; i < h_C.size(); i++)
        maxerr = std::max(maxerr, (double)std::fabs(h_C[i] - expected));
    bool correct = maxerr < expected * 1e-3;

    std::sort(kt.begin(), kt.end());
    std::sort(gt.begin(), gt.end());
    double k_med = kt[iters / 2], k_min = kt[0], g_med = gt[iters / 2];
    double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"onednn+custom\",\n");
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"matmul_median_us\": %.2f,\n", g_med);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    sycl::free(A, q); sycl::free(B, q); sycl::free(C, q);
    return correct ? 0 : 1;
}
