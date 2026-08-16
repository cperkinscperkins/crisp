/*
 * Chapter 5 (Endeavor 150) — THE STRONG INTEL BASELINE: oneDNN fusing ReLU itself.
 *
 * dnnl::matmul with a post-op (eltwise_relu), so the activation happens inside the library's
 * own kernel — no second launch, no HBM round trip.  This is the Intel analog of cuBLASLt's
 * CUBLASLT_EPILOGUE_RELU, and it is the contender that makes this chapter honest.
 *
 * WHY IT MATTERS THAT THIS EXISTS.  Until now the Intel side compared Crisp only against
 * oneMKL, which has NO epilogue parameter at all and therefore must pay a separate kernel for
 * any activation.  Beating that at plain relu proves less than it looks: it beats a library
 * that was never allowed to compete.  oneDNN *can* fuse relu, so this is the like-for-like
 * comparison, and losing to it would be a fair result.
 *
 * The chapter-6 twin (onednn_optimal.cpp) is where the asymmetry shows: there the activation is
 * a quadratic tail, which is not one of oneDNN's fixed eltwise primitives, so even oneDNN has
 * to fall back to a second kernel while Crisp does not.
 *
 * TIMING is via sycl_interop::execute, which returns a sycl::event — the same event-based
 * measurement every other contender in this chapter uses, rather than host wall clock.
 *
 * A = B = 1 so every C == K, and relu(K) == K, so the correctness gate is unchanged and exact.
 *
 * Build: icpx -fsycl -O3 ... onednn_fused.cpp -ldnnl -o onednn_fused
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
    post_ops po;
    po.append_eltwise(algorithm::eltwise_relu, 0.0f, 0.0f);   // <-- the fused epilogue
    attr.set_post_ops(po);

    auto pd = matmul::primitive_desc(eng, a_md, b_md, c_md, attr);
    auto prim = matmul(pd);

    memory a_mem(a_md, eng, A), b_mem(b_md, eng, B), c_mem(c_md, eng, C);
    std::unordered_map<int, memory> args = {
        {DNNL_ARG_SRC, a_mem}, {DNNL_ARG_WEIGHTS, b_mem}, {DNNL_ARG_DST, c_mem}};

    for (int i = 0; i < warmup; i++) sycl_interop::execute(prim, strm, args).wait();

    std::vector<double> kt(iters);
    for (int i = 0; i < iters; i++) {
        auto ev = sycl_interop::execute(prim, strm, args);
        ev.wait();
        auto t0 = ev.get_profiling_info<sycl::info::event_profiling::command_start>();
        auto t1 = ev.get_profiling_info<sycl::info::event_profiling::command_end>();
        kt[i] = (double)(t1 - t0) / 1000.0;   // ns -> us
    }

    q.memcpy(h_C.data(), C, h_C.size() * 4).wait();
    double expected = (double)K, maxerr = 0.0;      // A=B=1 => C == K, and relu(K) == K
    for (size_t i = 0; i < h_C.size(); i++)
        maxerr = std::max(maxerr, (double)std::fabs(h_C[i] - expected));
    bool correct = maxerr < expected * 1e-3;

    std::sort(kt.begin(), kt.end());
    double k_med = kt[iters / 2], k_min = kt[0];
    double gflops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;

    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"onednn+relu-fused\",\n");
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", maxerr);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gflops);

    sycl::free(A, q); sycl::free(B, q); sycl::free(C, q);
    return correct ? 0 : 1;
}
