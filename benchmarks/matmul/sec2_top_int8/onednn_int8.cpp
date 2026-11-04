/*
 * Section 2 top, int8 (Endeavour 207) -- THE INTEL LIBRARY PEER: oneDNN s8 x s8 -> s32.
 *
 * oneMKL's integer GEMM (gemm_s8u8s32) is a CPU routine; on an Intel GPU the int8 matmul lives in
 * oneDNN, so oneDNN is the library this lane is measured against.  Same contract as the Crisp
 * kernel: A is M x K s8, B is K x N s8, C is M x N s32, all row-major (tag::ab), no scales, no
 * zero points, no post-ops -- the raw MMA.
 *
 * TIMING is via sycl_interop::execute, which returns a sycl::event -- the same event-based
 * measurement the other Intel peers use, rather than host wall clock.
 *
 * Inputs are the shared fill (A = flat % 5, B = flat % 3), so every C is an exact small integer and
 * the gate is exact (max_abs_err must be 0).
 *
 * Build: icpx -fsycl -O3 ... onednn_int8.cpp -ldnnl -o onednn_int8
 */
#include <sycl/sycl.hpp>
#include "../common/fill_sycl.hpp"
#include <oneapi/dnnl/dnnl.hpp>
#include <oneapi/dnnl/dnnl_sycl.hpp>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <unordered_map>
#include <vector>

using namespace dnnl;

int main(int argc, char** argv) {
    auto wall_start = std::chrono::high_resolution_clock::now();
    int M      = argc > 1 ? atoi(argv[1]) : 256;
    int N      = argc > 2 ? atoi(argv[2]) : 256;
    int K      = argc > 3 ? atoi(argv[3]) : 256;
    int warmup = argc > 4 ? atoi(argv[4]) : 20;
    int iters  = argc > 5 ? atoi(argv[5]) : 100;

    sycl::queue q{sycl::gpu_selector_v, sycl::property::queue::enable_profiling{}};
    int8_t*  A = sycl::malloc_device<int8_t>((size_t)M * K, q);
    int8_t*  B = sycl::malloc_device<int8_t>((size_t)K * N, q);
    int32_t* C = sycl::malloc_device<int32_t>((size_t)M * N, q);
    crisp_bench::sycl_fill(q, A, (size_t)M * K, crisp_bench::FILL_MOD_A);
    crisp_bench::sycl_fill(q, B, (size_t)K * N, crisp_bench::FILL_MOD_B);
    crisp_bench::sycl_zero(q, C, (size_t)M * N);

    engine eng = sycl_interop::make_engine(q.get_device(), q.get_context());
    stream  strm = sycl_interop::make_stream(eng, q);
    using dt = memory::data_type;
    using tag = memory::format_tag;
    auto a_md = memory::desc({M, K}, dt::s8,  tag::ab);
    auto b_md = memory::desc({K, N}, dt::s8,  tag::ab);
    auto c_md = memory::desc({M, N}, dt::s32, tag::ab);
    auto pd = matmul::primitive_desc(eng, a_md, b_md, c_md);
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

    const crisp_bench::VerifyResult vr = crisp_bench::sycl_verify(q, C, (uint64_t)M, (uint64_t)N, (uint64_t)K);
    const bool correct = vr.verified && vr.max_abs_err == 0.0;
    std::sort(kt.begin(), kt.end());
    double k_med = kt[iters / 2], k_min = kt[0];
    double gops = (2.0 * M * N * K) / (k_med / 1e6) / 1e9;
    auto wall_end = std::chrono::high_resolution_clock::now();
    double wall_time_ms = std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    printf("{\n  \"algorithm\": \"matmul\",\n  \"implementation\": \"onednn-s8s8s32\",\n");
    printf("  \"impl_detail\": \"%s\",\n", pd.impl_info_str());
    printf("  \"N\": %d, \"M\": %d, \"K\": %d,\n", N, M, K);
    printf("  \"correct\": %s,\n  \"max_abs_err\": %.3e,\n", correct ? "true" : "false", vr.max_abs_err);
    printf("  \"wall_time_ms\": %.2f,\n", wall_time_ms);
    printf("  \"kernel_median_us\": %.2f,\n  \"kernel_min_us\": %.2f,\n", k_med, k_min);
    printf("  \"gflops\": %.2f\n}\n", gops);

    sycl::free(A, q); sycl::free(B, q); sycl::free(C, q);
    return correct ? 0 : 1;
}
