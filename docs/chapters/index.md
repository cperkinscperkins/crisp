# Crisp Language Specification


## CRISP - Lisp for developing GPU Kernels
- [Overview](01_crisp_lisp_for_developing_gpu_kernels/01_overview.md)
- [Focus](01_crisp_lisp_for_developing_gpu_kernels/02_focus.md)
- [Major Features of the Crisp language and tools](01_crisp_lisp_for_developing_gpu_kernels/03_major_features_of_the_crisp_language_and_tools.md)
- [Differences From Lisp](01_crisp_lisp_for_developing_gpu_kernels/04_differences_from_lisp.md)
- [Commonalities with C++](01_crisp_lisp_for_developing_gpu_kernels/05_commonalities_with_c.md)

## Thread Level / Grid Level / Dispatch ✅
- [Why This is Different from C++/CUDA](02_thread_level_grid_level_dispatch/01_why_this_is_different_from_ccuda.md)

## Terminology: Storage Handles ✅

## Top Level Execution Constructs ✅
- [`def-kernel` ✅](04_top_level_execution_constructs/01_def_kernel.md)
- [`def-function` ✅](04_top_level_execution_constructs/02_def_function.md)
- [`def-grid-function` ✅](04_top_level_execution_constructs/03_def_grid_function.md)

## Return Storage Handle Pattern `&out` ✅
- [`&out` and differentiation ✅](05_return_storage_handle_pattern_out/01_out_and_differentiation.md)
- [`&out` and performance ✅](05_return_storage_handle_pattern_out/02_out_and_performance.md)

## Argument Passing and Side Channels ✅

## Crisp Types ✅
- [Base Numeric Types ✅](07_crisp_types/01_base_numeric_types.md)
- [Vector Numeric Types ✅](07_crisp_types/02_vector_numeric_types.md)
- [Numeric Type Promotion, Casting, Conversion ✅](07_crisp_types/03_numeric_type_promotion_casting_conversion.md)
- [Quantized Integers and Complex Numbers 📝](07_crisp_types/04_quantized_integers_and_complex_numbers.md)
- [Other Basic Types ⚠️](07_crisp_types/05_other_basic_types.md)
- [Declaring Types - Functions ✅](07_crisp_types/06_declaring_types_functions.md)
- [Function Overloading ✅](07_crisp_types/07_function_overloading.md)
- [Recursion Disallowed ✅](07_crisp_types/08_recursion_disallowed.md)
- [Declaring Types - Kernels ✅](07_crisp_types/09_declaring_types_kernels.md)
- [Implementation Notes](07_crisp_types/10_implementation_notes.md)
- [member data rules](07_crisp_types/11_member_data_rules.md)
- [layout and alignment](07_crisp_types/12_layout_and_alignment.md)
- [type constraints: is-XXXX?](07_crisp_types/13_type_constraints_is_xxxx.md)
- [compile-time properties](07_crisp_types/14_compile_time_properties.md)
- [type names vs. type constructors](07_crisp_types/15_type_names_vs_type_constructors.md)
- [member access: `XXXX~`](07_crisp_types/16_member_access_xxxx.md)
- [def-setter ✅](07_crisp_types/17_def_setter.md)
- [def-record ✅](07_crisp_types/18_def_record.md)
- [Array Type ⚠️](07_crisp_types/19_array_type.md)
- [Incomplete Types ✅](07_crisp_types/20_incomplete_types.md)
- [Template Types ✅](07_crisp_types/21_template_types.md)
- [def-constraint 📝](07_crisp_types/22_def_constraint.md)
- [def-type-function 📝](07_crisp_types/23_def_type_function.md)

## GPU Memory ⚠️

## Storage Handle Types ✅
- [Alignment ✅](09_storage_handle_types/01_alignment.md)
- [Contiguity  (aka row-major vs col-major) ✅](09_storage_handle_types/02_contiguity_aka_row_major_vs_col_major.md)
- [Storage Properties ✅](09_storage_handle_types/03_storage_properties.md)
- [Cell Properties ✅](09_storage_handle_types/04_cell_properties.md)
- [Vector / Matrix /Tensor Properties ✅](09_storage_handle_types/05_vector_matrix_tensor_properties.md)
- [Element Access ✅](09_storage_handle_types/06_element_access.md)
- [Helper Functions ✅](09_storage_handle_types/07_helper_functions.md)
- [Member Data Rules ✅](09_storage_handle_types/08_member_data_rules.md)
- [Storage Handle Type Definitions ⚠️](09_storage_handle_types/09_storage_handle_type_definitions.md)
- [Storage Handle Arguments for Kernels ✅](09_storage_handle_types/10_storage_handle_arguments_for_kernels.md)
- [Creating Storage Handle Views ✅](09_storage_handle_types/11_creating_storage_handle_views.md)
- [Reduce Boilerplate: `in-XXXX` and `out-XXXX` 📝](09_storage_handle_types/12_reduce_boilerplate_in_xxxx_and_out_xxxx.md)
- [soa-vector 📝](09_storage_handle_types/13_soa_vector.md)
- [def-const 📝](09_storage_handle_types/14_def_const.md)
- [def-parameter 📝](09_storage_handle_types/15_def_parameter.md)
- [def-const-vec 📝](09_storage_handle_types/16_def_const_vec.md)
- [Side Channel Storage Handles ✅](09_storage_handle_types/17_side_channel_storage_handles.md)
- [Tensors & Matrices ✅](09_storage_handle_types/18_tensors_matrices.md)
- [Matrices ✅](09_storage_handle_types/19_matrices.md)
- [Type Aliases and Type Constructors ✅](09_storage_handle_types/20_type_aliases_and_type_constructors.md)
- [Derived Types ✅](09_storage_handle_types/21_derived_types.md)
- [Continuation Kernels 📝](09_storage_handle_types/22_continuation_kernels.md)
- [First Order Functions ⚠️](09_storage_handle_types/23_first_order_functions.md)
- [No First Order Types 📝](09_storage_handle_types/24_no_first_order_types.md)
- [Enumerations ✅](09_storage_handle_types/25_enumerations.md)
- [Maybe Type 📝](09_storage_handle_types/26_maybe_type.md)

## `let` ✅

## `set!` ✅

## `declare` ⚠️
- [`declare` and templates 📝](12_declare/01_declare_and_templates.md)
- [Other `declare` directives](12_declare/02_other_declare_directives.md)
- [For `defmacro` writers](12_declare/03_for_defmacro_writers.md)
- [For Static Analysis 📝](12_declare/04_for_static_analysis.md)

## Control Flow ✅
- [Single Task 📝](13_control_flow/01_single_task.md)
- [when-thread-is / abs-when-thread-is 📝](13_control_flow/02_when_thread_is_abs_when_thread_is.md)
- [when-thread-in-group-is / when-group-is 📝](13_control_flow/03_when_thread_in_group_is_when_group_is.md)
- [when-global-linear-id-is / when-local-linear-id-is 📝](13_control_flow/04_when_global_linear_id_is_when_local_linear_id_is.md)
- [when-is-last-workgroup 📝](13_control_flow/05_when_is_last_workgroup.md)
- [when-is-last-warp / when-is-last-thread 📝](13_control_flow/06_when_is_last_warp_when_is_last_thread.md)
- [Hoisting and Enqueing a Kernel ⚠️](13_control_flow/07_hoisting_and_enqueing_a_kernel.md)
- [Latency Hiding - warp sizes and workgroup sizes ✅](13_control_flow/08_latency_hiding_warp_sizes_and_workgroup_sizes.md)
- [One Thread Per Element ✅](13_control_flow/09_one_thread_per_element.md)
- [Looping - Grid Stride ✅](13_control_flow/10_looping_grid_stride.md)
- [General Purpose: `tensor-stride`, `grid-stride`,  `tile-stride` and `hardware-stride` ✅](13_control_flow/11_general_purpose_tensor_stride_grid_stride_tile_stride_and_hardware_stride.md)
- [workgroup-stride ✅](13_control_flow/12_workgroup_stride.md)
- [Looping -- Uniform Loops ✅](13_control_flow/13_looping_uniform_loops.md)
- [Looping Constructs ✅](13_control_flow/14_looping_constructs.md)
- [Grid Level Operations ✅](13_control_flow/15_grid_level_operations.md)
- [Workgroup Level Operations ✅](13_control_flow/16_workgroup_level_operations.md)
- [Barriers and Fences ✅](13_control_flow/17_barriers_and_fences.md)
- [Sum a Vector using Local Memory ✅](13_control_flow/18_sum_a_vector_using_local_memory.md)
- [Warps & Shuffles 📝](13_control_flow/19_warps_shuffles.md)
- [in-warp 📝](13_control_flow/20_in_warp.md)
- [Sum a Vector using Warps and Shuffles 📝](13_control_flow/21_sum_a_vector_using_warps_and_shuffles.md)

## Bit Twiddling Operations 📝
- [`op-popcount` 📝](14_bit_twiddling_operations/01_op_popcount.md)
- [`op-count-leading-zeros` / `op-count-trailing-zeros` 📝](14_bit_twiddling_operations/02_op_count_leading_zeros_op_count_trailing_zeros.md)
- [`op-find-msb` / `op-find-lsb` 📝](14_bit_twiddling_operations/03_op_find_msb_op_find_lsb.md)
- [`op-bit-reverse` 📝](14_bit_twiddling_operations/04_op_bit_reverse.md)
- [`op-bitfield-extract` / `op-bitfield-insert` 📝](14_bit_twiddling_operations/05_op_bitfield_extract_op_bitfield_insert.md)

## Hardware Bit Packing / Unpacking 📝
- [`op-pack-11` / `op-unpack-11` 📝](15_hardware_bit_packing_unpacking/01_op_pack_11_op_unpack_11.md)
- [`op-pack-half-2x16` / `op-unpack-half-2x16` 📝](15_hardware_bit_packing_unpacking/02_op_pack_half_2x16_op_unpack_half_2x16.md)
- [`op-pack-unorm-4x8` / `op-unpack-unorm-4x8` 📝](15_hardware_bit_packing_unpacking/03_op_pack_unorm_4x8_op_unpack_unorm_4x8.md)
- [`op-pack-snorm-4x8` / `op-unpack-snorm-4x8` 📝](15_hardware_bit_packing_unpacking/04_op_pack_snorm_4x8_op_unpack_snorm_4x8.md)
- [`op-pack-unorm-2x16` / `op-unpack-unorm-2x16` 📝](15_hardware_bit_packing_unpacking/05_op_pack_unorm_2x16_op_unpack_unorm_2x16.md)
- [`op-pack-double-2x32` / `op-unpack-double-2x32` 📝](15_hardware_bit_packing_unpacking/06_op_pack_double_2x32_op_unpack_double_2x32.md)
- [`op-pack-rgb-9e5` (Shared Exponent)  Pack only.](15_hardware_bit_packing_unpacking/07_op_pack_rgb_9e5_shared_exponent_pack_only.md)

## Branching ⚠️
- [Cost of Divergent Branching](16_branching/01_cost_of_divergent_branching.md)
- [Predicated Selection 📝](16_branching/02_predicated_selection.md)

## Higher Order Function Operations ✅
- [Compile Time Resolution ✅](17_higher_order_function_operations/01_compile_time_resolution.md)
- [Lambda No, Curry Yes 📝](17_higher_order_function_operations/02_lambda_no_curry_yes.md)
- [map 📝](17_higher_order_function_operations/03_map.md)
- [Invoking Functions: `funcall` ✅](17_higher_order_function_operations/04_invoking_functions_funcall.md)

## Shop Local, Act Global

## Reduce Variants 📝
- [reduce vector 📝](19_reduce_variants/01_reduce_vector.md)

## Boolean Reductions 📝
- [`all?` / `none?` 📝](20_boolean_reductions/01_all_none.md)
- [`any?` 📝](20_boolean_reductions/02_any.md)

## Segmented Reduction 📝

## Filtering / Prefix-Sum Scan 📝
- [`prepare-for-scan--value` 📝](22_filtering_prefix_sum_scan/01_prepare_for_scan_value.md)
- [`prepare-for-scan--index`](22_filtering_prefix_sum_scan/02_prepare_for_scan_index.md)
- [`exclusive-scan-workgroup` 📝](22_filtering_prefix_sum_scan/03_exclusive_scan_workgroup.md)
- [`inclusive-scan-workgroup` 📝](22_filtering_prefix_sum_scan/04_inclusive_scan_workgroup.md)
- [global-exclusive-scan 📝](22_filtering_prefix_sum_scan/05_global_exclusive_scan.md)
- [global-inclusive-scan 📝](22_filtering_prefix_sum_scan/06_global_inclusive_scan.md)
- [Word Count With Exclusive Scan](22_filtering_prefix_sum_scan/07_word_count_with_exclusive_scan.md)
- [`filter` 📝](22_filtering_prefix_sum_scan/08_filter.md)

## Gather / Scatter 📝

## Sorting 📝
- [Bitonic Sort 📝](24_sorting/01_bitonic_sort.md)
- [Radix Sort 📝](24_sorting/02_radix_sort.md)

## Atomics ⚠️
- [Atomic Operations ⚠️](25_atomics/01_atomic_operations.md)

## Vector and Tensor Operations 📝
- [`fill` and `iota` 📝](26_vector_and_tensor_operations/01_fill_and_iota.md)
- [`copy` 📝](26_vector_and_tensor_operations/02_copy.md)
- [dot product 📝](26_vector_and_tensor_operations/03_dot_product.md)
- [matrix multiplication (matmul) 📝](26_vector_and_tensor_operations/04_matrix_multiplication_matmul.md)
- [Matrix Vector Multiply `(m*v M v)` 📝](26_vector_and_tensor_operations/05_matrix_vector_multiply_mv_m_v.md)
- [Convolution 📝](26_vector_and_tensor_operations/06_convolution.md)

## Math Operations & Arithmetic ✅
- [Floating Point Precision ✅](27_math_operations_arithmetic/01_floating_point_precision.md)
- [Floating Point Only Operations ⚠️](27_math_operations_arithmetic/02_floating_point_only_operations.md)
- [Transcendental Functions ✅](27_math_operations_arithmetic/03_transcendental_functions.md)
- [Floating Point and Integer Operations ✅](27_math_operations_arithmetic/04_floating_point_and_integer_operations.md)
- [Integer Only Operations 📝](27_math_operations_arithmetic/05_integer_only_operations.md)
- [Integer Division ✅](27_math_operations_arithmetic/06_integer_division.md)
- [Hardware Supported Math Operations 📝](27_math_operations_arithmetic/07_hardware_supported_math_operations.md)

## Quantized Integers 📝
- [Quantized Integer Types 📝](28_quantized_integers/01_quantized_integer_types.md)

## Low Precision Floats ("microfloats") 📝
- [Format Wars](29_low_precision_floats_microfloats/01_format_wars.md)
- [Micro Float Types 📝](29_low_precision_floats_microfloats/02_micro_float_types.md)
- [def-microfloat-block 📝](29_low_precision_floats_microfloats/03_def_microfloat_block.md)
- [blockwise operations 📝](29_low_precision_floats_microfloats/04_blockwise_operations.md)
- [Vector Conversion Operations 📝](29_low_precision_floats_microfloats/05_vector_conversion_operations.md)
- [element-wise access 📝](29_low_precision_floats_microfloats/06_element_wise_access.md)

## Complex Numbers 📝
- [soa-vector and complex 📝](30_complex_numbers/01_soa_vector_and_complex.md)

## Fast Fourier Transform (FFT) 📝

## Fused Softmax 📝

## Builtin GPU Functions ✅

## Forgotten 📝

## Strings - Compile Time and Run Time 📝
- [Compile Time Strings 📝](35_strings_compile_time_and_run_time/01_compile_time_strings.md)
- [Runtime Strings 📝](35_strings_compile_time_and_run_time/02_runtime_strings.md)

## Logging and Debugging 📝
- [Compile Time Output and Assert ✅](36_logging_and_debugging/01_compile_time_output_and_assert.md)
- [`(die "disaster")` ⚠️](36_logging_and_debugging/02_die_disaster.md)
- [Runtime Asserts ⚠️](36_logging_and_debugging/03_runtime_asserts.md)
- [Runtime Logging 📝](36_logging_and_debugging/04_runtime_logging.md)
- [Logging Utilities 📝](36_logging_and_debugging/05_logging_utilities.md)

## Debugging Implementation 📝
- [So You Want Debug Logging](37_debugging_implementation/01_so_you_want_debug_logging.md)
- [Subdivide Subdivide Subdivide - the "other" debug flags](37_debugging_implementation/02_subdivide_subdivide_subdivide_the_other_debug_flags.md)
- [Common Debug Flag Configurations 📝](37_debugging_implementation/03_common_debug_flag_configurations.md)

## Conditional Compilation ✅
- [defmacro ✅](38_conditional_compilation/01_defmacro.md)
- [target-has / device-has 📝](38_conditional_compilation/02_target_has_device_has.md)

## Assist defmacro Development 📝

## `entrypoint` 📝

## `defmacro` and `T`

## Static Analysys 📝
- [declaim ⚠️](42_static_analysys/01_declaim.md)
- [check-coalesce 📝](42_static_analysys/02_check_coalesce.md)
- [check-bank-conflicts 📝](42_static_analysys/03_check_bank_conflicts.md)
- [check-divergence 📝](42_static_analysys/04_check_divergence.md)
- [max-registers / warn-max-registers 📝](42_static_analysys/05_max_registers_warn_max_registers.md)
- [check-barriers 📝](42_static_analysys/06_check_barriers.md)
- [miscellaneous ⚠️](42_static_analysys/07_miscellaneous.md)

## Auto Differentiation (AD) ✅
- [`--differentiate` ✅](43_auto_differentiation_ad/01_differentiate.md)

## Foreign Function Interface (FFI) ✅
- [`def-foreign-function` ✅](44_foreign_function_interface_ffi/01_def_foreign_function.md)
- [pointers and handles: `c-pointer` ✅](44_foreign_function_interface_ffi/02_pointers_and_handles_c_pointer.md)
- [`base-ptr~` accessor ✅](44_foreign_function_interface_ffi/03_base_ptr_accessor.md)
- [handles ✅](44_foreign_function_interface_ffi/04_handles.md)
- [basic invocation ✅](44_foreign_function_interface_ffi/05_basic_invocation.md)
- [deferred invocation 📝](44_foreign_function_interface_ffi/06_deferred_invocation.md)

## Automatic Differentiation over the FFI Boundary
- [The VJP Signature Rule (vetted)](45_automatic_differentiation_over_the_ffi_boundary/01_the_vjp_signature_rule_vetted.md)
- [Signature mapping examples](45_automatic_differentiation_over_the_ffi_boundary/02_signature_mapping_examples.md)
- [Example 1 — A transcendental, no buffers](45_automatic_differentiation_over_the_ffi_boundary/03_example_1_a_transcendental_no_buffers.md)
- [Example 2 — A buffer op with shadow accumulation (the aggressive case)](45_automatic_differentiation_over_the_ffi_boundary/04_example_2_a_buffer_op_with_shadow_accumulation_the_aggressive_case.md)

## Topologically Aware Compilation ✅

## Hardware Profiles ✅
- [`def-hardware-profile`  ✅](47_hardware_profiles/01_def_hardware_profile.md)
- [`:mma-shapes` ✅](47_hardware_profiles/02_mma_shapes.md)
- [`:mma-lowerings` ✅](47_hardware_profiles/03_mma_lowerings.md)
- [Crisp predefined hardware profiles](47_hardware_profiles/04_crisp_predefined_hardware_profiles.md)
- [Probing Hardware Profile ✅](47_hardware_profiles/05_probing_hardware_profile.md)

## Topologically Aware Async
- [`make-async-barrier` ✅](48_topologically_aware_async/01_make_async_barrier.md)
- [`load-tile` ✅](48_topologically_aware_async/02_load_tile.md)
- [`load-tile-at` ✅](48_topologically_aware_async/03_load_tile_at.md)
- [`store-tile` ✅](48_topologically_aware_async/04_store_tile.md)
- [`store-tile-at` ✅](48_topologically_aware_async/05_store_tile_at.md)
- [`await` ✅](48_topologically_aware_async/06_await.md)
- [`signal` ✅](48_topologically_aware_async/07_signal.md)
- [More Tile helpers ✅](48_topologically_aware_async/08_more_tile_helpers.md)
- [Crisp Terminology](48_topologically_aware_async/09_crisp_terminology.md)
- [Sync Operations ✅](48_topologically_aware_async/10_sync_operations.md)
- [Semaphore Operations 📝](48_topologically_aware_async/11_semaphore_operations.md)
- [semaphore-acquire](48_topologically_aware_async/12_semaphore_acquire.md)
- [semaphore-release](48_topologically_aware_async/13_semaphore_release.md)

## Clusters and Distributed Shared Memory
- [Semantics and multicasting](49_clusters_and_distributed_shared_memory/01_semantics_and_multicasting.md)

## Rings ✅
- [`ring-get` ✅](50_rings/01_ring_get.md)
- [`make-register-tile-ring` ✅](50_rings/02_make_register_tile_ring.md)
- [`make-async-barrier-ring` ✅](50_rings/03_make_async_barrier_ring.md)

## Warp Specialization ✅

## Matrix Multiplication ✅
- [`mma-lowering` ✅](52_matrix_multiplication/01_mma_lowering.md)
- [`make-register-tile` ✅](52_matrix_multiplication/02_make_register_tile.md)
- [matrix-multiply-tile-stride ✅](52_matrix_multiplication/03_matrix_multiply_tile_stride.md)
- [inner-dimension ✅](52_matrix_multiplication/04_inner_dimension.md)
- [outer-dimensions ✅](52_matrix_multiplication/05_outer_dimensions.md)
- [fill-tile ✅](52_matrix_multiplication/06_fill_tile.md)
- [Autodiff ✅](52_matrix_multiplication/07_autodiff.md)

## Matrix Multiplication Optimization — Two Vendor Arcs

## Optimizing NVIDIA MMA
- [Chapter 1 — Basic Matrix Multiply with async tile loading](54_optimizing_nvidia_mma/01_chapter_1_basic_matrix_multiply_with_async_tile_loading.md)
- [mma-accumulate-via-tile ✅](54_optimizing_nvidia_mma/02_mma_accumulate_via_tile.md)
- [map-elements! ✅ — fusing your own code into the epilogue](54_optimizing_nvidia_mma/03_map_elements_fusing_your_own_code_into_the_epilogue.md)
- [Fragment primitives (the low-level building blocks)](54_optimizing_nvidia_mma/04_fragment_primitives_the_low_level_building_blocks.md)
- [Matrix Multiply with pipelining ✅](54_optimizing_nvidia_mma/05_matrix_multiply_with_pipelining.md)
- [Matrix Multiply with Pipelining via Warp Specialization ✅](54_optimizing_nvidia_mma/06_matrix_multiply_with_pipelining_via_warp_specialization.md)

## Optimizing Intel MMA
- [Operand layout: Intel MMA operands must be `:row-major` ✅](55_optimizing_intel_mma/01_operand_layout_intel_mma_operands_must_be_row_major.md)
- [Reusing the "Ring" Meme](55_optimizing_intel_mma/02_reusing_the_ring_meme.md)
- [The Optimal Intel Pipelined MMA](55_optimizing_intel_mma/03_the_optimal_intel_pipelined_mma.md)
- [Why this is the optimal shape for Intel](55_optimizing_intel_mma/04_why_this_is_the_optimal_shape_for_intel.md)
- [Hopper warpgroup MMA — `make-wgmma-accumulator` ✅ + `wgmma-accumulate-via-tile` ✅](55_optimizing_intel_mma/05_hopper_warpgroup_mma_make_wgmma_accumulator_wgmma_accumulate_via_tile.md)

## Deferred: cluster-scale topology (`def-topology` / `def-orchestration`)

## Hoisting and `def-orchestration` ⚠️
- [`def-orchestration` 📝](57_hoisting_and_def_orchestration/01_def_orchestration.md)
- [launch-sequential 📝](57_hoisting_and_def_orchestration/02_launch_sequential.md)
- [launch-kernel 📝](57_hoisting_and_def_orchestration/03_launch_kernel.md)
- [launch-parallel 📝](57_hoisting_and_def_orchestration/04_launch_parallel.md)

## Compiler Invocation and Options ✅
- [Output Targeting Options 📝](58_compiler_invocation_and_options/01_output_targeting_options.md)
- [Other Flags ⚠️](58_compiler_invocation_and_options/02_other_flags.md)
- [Compiliation Flags ✅](58_compiler_invocation_and_options/03_compiliation_flags.md)
- [Fast Compilation ✅](58_compiler_invocation_and_options/04_fast_compilation.md)
- [Compiler Invocations and Files ✅](58_compiler_invocation_and_options/05_compiler_invocations_and_files.md)

## Hoisting Code ✅

## In-Memory Compilation API 📝
- [C API 📝](60_in_memory_compilation_api/01_c_api.md)
- [Status Codes ✅](60_in_memory_compilation_api/02_status_codes.md)
- [Flags](60_in_memory_compilation_api/03_flags.md)

## APPENDIX #1 - Summary: set / get vars, storage handles, and structs

## APPENDIX #2 - Math with Quantized Ints and Microfloat
- [dot product and matmul 📝](62_appendix_2_math_with_quantized_ints_and_microfloat/01_dot_product_and_matmul.md)

## Acknowledgements ✅

## INDECES
- [def-](64_indeces/01_def.md)
- [control flow](64_indeces/02_control_flow.md)
- [Higher Order Function Operations](64_indeces/03_higher_order_function_operations.md)
- [Sorting](64_indeces/04_sorting.md)
- [Algorithms](64_indeces/05_algorithms.md)
- [Atomics](64_indeces/06_atomics.md)
- [Type Constraints](64_indeces/07_type_constraints.md)
- [other](64_indeces/08_other.md)
- [Hardware Operations](64_indeces/09_hardware_operations.md)
- [logging and debugging](64_indeces/10_logging_and_debugging.md)
- [static analysis](64_indeces/11_static_analysis.md)
- [hoisting and def-orchestration](64_indeces/12_hoisting_and_def_orchestration.md)
- [lisp](64_indeces/13_lisp.md)
- [To Do](64_indeces/14_to_do.md)
- [Memory](64_indeces/15_memory.md)
