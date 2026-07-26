# Crisp Language Specification


## CRISP - Lisp for developing GPU Kernels
- [Overview](01_crisp_lisp_for_developing_gpu_kernels/01_overview.md)
- [Focus](01_crisp_lisp_for_developing_gpu_kernels/02_focus.md)
- [Major Features of the Crisp language and tools](01_crisp_lisp_for_developing_gpu_kernels/03_major_features_of_the_crisp_language_and_tools.md)
- [Differences From Lisp](01_crisp_lisp_for_developing_gpu_kernels/04_differences_from_lisp.md)
- [Commonalities with C++](01_crisp_lisp_for_developing_gpu_kernels/05_commonalities_with_c.md)

## Thread Level / Grid Level / Dispatch ✅
- [Why This is Different from C++/CUDA](02_thread_level_grid_level_dispatch_/01_why_this_is_different_from_ccuda.md)

## Terminology: Storage Handles ✅

## Top Level Execution Constructs ✅
- [`def-kernel` ✅](04_top_level_execution_constructs_/01_def_kernel_.md)
- [`def-function` ✅](04_top_level_execution_constructs_/02_def_function_.md)
- [`def-grid-function` ✅](04_top_level_execution_constructs_/03_def_grid_function_.md)

## Return Storage Handle Pattern `&out` ✅
- [`&out` and differentiation ✅](05_return_storage_handle_pattern_out_/01_out_and_differentiation_.md)
- [`&out` and performance ✅](05_return_storage_handle_pattern_out_/02_out_and_performance_.md)

## Argument Passing and Side Channels ✅

## Crisp Types ✅
- [Base Numeric Types ✅](07_crisp_types_/01_base_numeric_types_.md)
- [Vector Numeric Types ✅](07_crisp_types_/02_vector_numeric_types_.md)
- [Numeric Type Promotion, Casting, Conversion ✅](07_crisp_types_/03_numeric_type_promotion_casting_conversion_.md)
- [Quantized Integers and Complex Numbers 📝](07_crisp_types_/04_quantized_integers_and_complex_numbers_.md)
- [Other Basic Types ⚠️](07_crisp_types_/05_other_basic_types_.md)
- [Declaring Types - Functions ✅](07_crisp_types_/06_declaring_types_functions_.md)
- [Function Overloading ✅](07_crisp_types_/07_function_overloading_.md)
- [Recursion Disallowed ✅](07_crisp_types_/08_recursion_disallowed_.md)
- [Declaring Types - Kernels ✅](07_crisp_types_/09_declaring_types_kernels_.md)
- [Implementation Notes](07_crisp_types_/10_implementation_notes.md)
- [member data rules](07_crisp_types_/11_member_data_rules.md)
- [layout and alignment](07_crisp_types_/12_layout_and_alignment.md)
- [type constraints: is-XXXX?](07_crisp_types_/13_type_constraints_is_xxxx.md)
- [compile-time properties](07_crisp_types_/14_compile_time_properties.md)
- [type names vs. type constructors](07_crisp_types_/15_type_names_vs_type_constructors.md)
- [member access: `XXXX~`](07_crisp_types_/16_member_access_xxxx.md)
- [def-setter ✅](07_crisp_types_/17_def_setter_.md)
- [def-record ✅](07_crisp_types_/18_def_record_.md)
- [Array Type ⚠️](07_crisp_types_/19_array_type_.md)
- [Incomplete Types ✅](07_crisp_types_/20_incomplete_types_.md)
- [Template Types ✅](07_crisp_types_/21_template_types_.md)
- [def-constraint 📝](07_crisp_types_/22_def_constraint_.md)
- [def-type-function 📝](07_crisp_types_/23_def_type_function_.md)

## GPU Memory ⚠️

## Storage Handle Types ✅
- [Alignment ✅](09_storage_handle_types_/01_alignment_.md)
- [Contiguity  (aka row-major vs col-major) ✅](09_storage_handle_types_/02_contiguity_aka_row_major_vs_col_major_.md)
- [Storage Properties ✅](09_storage_handle_types_/03_storage_properties_.md)
- [Cell Properties ✅](09_storage_handle_types_/04_cell_properties_.md)
- [Vector / Matrix /Tensor Properties ✅](09_storage_handle_types_/05_vector_matrix_tensor_properties_.md)
- [Element Access ✅](09_storage_handle_types_/06_element_access_.md)
- [Helper Functions ✅](09_storage_handle_types_/07_helper_functions_.md)
- [Member Data Rules ✅](09_storage_handle_types_/08_member_data_rules_.md)
- [Storage Handle Type Definitions ⚠️](09_storage_handle_types_/09_storage_handle_type_definitions_.md)
- [Storage Handle Arguments for Kernels ✅](09_storage_handle_types_/10_storage_handle_arguments_for_kernels_.md)
- [Creating Storage Handle Views ✅](09_storage_handle_types_/11_creating_storage_handle_views_.md)
- [Reduce Boilerplate: `in-XXXX` and `out-XXXX` 📝](09_storage_handle_types_/12_reduce_boilerplate_in_xxxx_and_out_xxxx_.md)
- [soa-vector 📝](09_storage_handle_types_/13_soa_vector_.md)
- [def-const 📝](09_storage_handle_types_/14_def_const_.md)
- [def-parameter 📝](09_storage_handle_types_/15_def_parameter_.md)
- [def-const-vec 📝](09_storage_handle_types_/16_def_const_vec_.md)
- [Side Channel Storage Handles ✅](09_storage_handle_types_/17_side_channel_storage_handles_.md)
- [Tensors & Matrices ✅](09_storage_handle_types_/18_tensors_matrices_.md)
- [Matrices ✅](09_storage_handle_types_/19_matrices_.md)
- [Type Aliases and Type Constructors ✅](09_storage_handle_types_/20_type_aliases_and_type_constructors_.md)
- [Derived Types ✅](09_storage_handle_types_/21_derived_types_.md)
- [Continuation Kernels 📝](09_storage_handle_types_/22_continuation_kernels_.md)
- [First Order Functions ⚠️](09_storage_handle_types_/23_first_order_functions_.md)
- [No First Order Types 📝](09_storage_handle_types_/24_no_first_order_types_.md)
- [Enumerations ✅](09_storage_handle_types_/25_enumerations_.md)
- [Maybe Type 📝](09_storage_handle_types_/26_maybe_type_.md)

## `let` ✅

## `set!` ✅

## `declare` ⚠️
- [`declare` and templates 📝](12_declare_/01_declare_and_templates_.md)
- [Other `declare` directives](12_declare_/02_other_declare_directives.md)
- [For `defmacro` writers](12_declare_/03_for_defmacro_writers.md)
- [For Static Analysis 📝](12_declare_/04_for_static_analysis_.md)

## Control Flow ✅
- [Single Task 📝](13_control_flow_/01_single_task_.md)
- [when-thread-is / abs-when-thread-is 📝](13_control_flow_/02_when_thread_is_abs_when_thread_is_.md)
- [when-thread-in-group-is / when-group-is 📝](13_control_flow_/03_when_thread_in_group_is_when_group_is_.md)
- [when-global-linear-id-is / when-local-linear-id-is 📝](13_control_flow_/04_when_global_linear_id_is_when_local_linear_id_is_.md)
- [when-is-last-workgroup 📝](13_control_flow_/05_when_is_last_workgroup_.md)
- [when-is-last-warp / when-is-last-thread 📝](13_control_flow_/06_when_is_last_warp_when_is_last_thread_.md)
- [Hoisting and Enqueing a Kernel ⚠️](13_control_flow_/07_hoisting_and_enqueing_a_kernel_.md)
- [Latency Hiding - warp sizes and workgroup sizes ✅](13_control_flow_/08_latency_hiding_warp_sizes_and_workgroup_sizes_.md)
- [One Thread Per Element ✅](13_control_flow_/09_one_thread_per_element_.md)
- [Looping - Grid Stride ✅](13_control_flow_/10_looping_grid_stride_.md)
- [General Purpose: `tensor-stride`, `grid-stride`,  `tile-stride` and `hardware-stride` ✅](13_control_flow_/11_general_purpose_tensor_stride_grid_stride_tile_stride_and_hardware_stride_.md)
- [workgroup-stride ✅](13_control_flow_/12_workgroup_stride_.md)
- [Looping -- Uniform Loops ✅](13_control_flow_/13_looping_uniform_loops_.md)
- [Looping Constructs ✅](13_control_flow_/14_looping_constructs_.md)
- [Grid Level Operations ✅](13_control_flow_/15_grid_level_operations_.md)
- [Workgroup Level Operations ✅](13_control_flow_/16_workgroup_level_operations_.md)
- [Barriers and Fences ✅](13_control_flow_/17_barriers_and_fences_.md)
- [Sum a Vector using Local Memory ✅](13_control_flow_/18_sum_a_vector_using_local_memory_.md)
- [Warps & Shuffles 📝](13_control_flow_/19_warps_shuffles_.md)
- [in-warp 📝](13_control_flow_/20_in_warp_.md)
- [Sum a Vector using Warps and Shuffles 📝](13_control_flow_/21_sum_a_vector_using_warps_and_shuffles_.md)

## Bit Twiddling Operations 📝
- [`op-popcount` 📝](14_bit_twiddling_operations_/01_op_popcount_.md)
- [`op-count-leading-zeros` / `op-count-trailing-zeros` 📝](14_bit_twiddling_operations_/02_op_count_leading_zeros_op_count_trailing_zeros_.md)
- [`op-find-msb` / `op-find-lsb` 📝](14_bit_twiddling_operations_/03_op_find_msb_op_find_lsb_.md)
- [`op-bit-reverse` 📝](14_bit_twiddling_operations_/04_op_bit_reverse_.md)
- [`op-bitfield-extract` / `op-bitfield-insert` 📝](14_bit_twiddling_operations_/05_op_bitfield_extract_op_bitfield_insert_.md)

## Hardware Bit Packing / Unpacking 📝
- [`op-pack-11` / `op-unpack-11` 📝](15_hardware_bit_packing_unpacking_/01_op_pack_11_op_unpack_11_.md)
- [`op-pack-half-2x16` / `op-unpack-half-2x16` 📝](15_hardware_bit_packing_unpacking_/02_op_pack_half_2x16_op_unpack_half_2x16_.md)
- [`op-pack-unorm-4x8` / `op-unpack-unorm-4x8` 📝](15_hardware_bit_packing_unpacking_/03_op_pack_unorm_4x8_op_unpack_unorm_4x8_.md)
- [`op-pack-snorm-4x8` / `op-unpack-snorm-4x8` 📝](15_hardware_bit_packing_unpacking_/04_op_pack_snorm_4x8_op_unpack_snorm_4x8_.md)
- [`op-pack-unorm-2x16` / `op-unpack-unorm-2x16` 📝](15_hardware_bit_packing_unpacking_/05_op_pack_unorm_2x16_op_unpack_unorm_2x16_.md)
- [`op-pack-double-2x32` / `op-unpack-double-2x32` 📝](15_hardware_bit_packing_unpacking_/06_op_pack_double_2x32_op_unpack_double_2x32_.md)
- [`op-pack-rgb-9e5` (Shared Exponent)  Pack only.](15_hardware_bit_packing_unpacking_/07_op_pack_rgb_9e5_shared_exponent_pack_only.md)

## Branching ⚠️
- [Cost of Divergent Branching](16_branching_/01_cost_of_divergent_branching.md)
- [Predicated Selection 📝](16_branching_/02_predicated_selection_.md)

## Higher Order Function Operations ✅
- [Compile Time Resolution ✅](17_higher_order_function_operations_/01_compile_time_resolution_.md)
- [Lambda No, Curry Yes 📝](17_higher_order_function_operations_/02_lambda_no_curry_yes_.md)
- [map 📝](17_higher_order_function_operations_/03_map_.md)
- [Invoking Functions: `funcall` ✅](17_higher_order_function_operations_/04_invoking_functions_funcall_.md)

## Shop Local, Act Global

## Reduce Variants 📝
- [reduce vector 📝](19_reduce_variants_/01_reduce_vector_.md)

## Boolean Reductions 📝
- [`all?` / `none?` 📝](20_boolean_reductions_/01_all_none_.md)
- [`any?` 📝](20_boolean_reductions_/02_any_.md)

## Segmented Reduction 📝

## Filtering / Prefix-Sum Scan 📝
- [`prepare-for-scan--value` 📝](22_filtering_prefix_sum_scan_/01_prepare_for_scan_value_.md)
- [`prepare-for-scan--index`](22_filtering_prefix_sum_scan_/02_prepare_for_scan_index.md)
- [`exclusive-scan-workgroup` 📝](22_filtering_prefix_sum_scan_/03_exclusive_scan_workgroup_.md)
- [`inclusive-scan-workgroup` 📝](22_filtering_prefix_sum_scan_/04_inclusive_scan_workgroup_.md)
- [global-exclusive-scan 📝](22_filtering_prefix_sum_scan_/05_global_exclusive_scan_.md)
- [global-inclusive-scan 📝](22_filtering_prefix_sum_scan_/06_global_inclusive_scan_.md)
- [Word Count With Exclusive Scan](22_filtering_prefix_sum_scan_/07_word_count_with_exclusive_scan.md)
- [`filter` 📝](22_filtering_prefix_sum_scan_/08_filter_.md)

## Gather / Scatter 📝

## Sorting 📝
- [Bitonic Sort 📝](24_sorting_/01_bitonic_sort_.md)
- [Radix Sort 📝](24_sorting_/02_radix_sort_.md)

## Atomics ⚠️
- [Atomic Operations ⚠️](25_atomics_/01_atomic_operations_.md)

## Vector and Tensor Operations 📝
- [`fill` and `iota` 📝](26_vector_and_tensor_operations_/01_fill_and_iota_.md)
- [`copy` 📝](26_vector_and_tensor_operations_/02_copy_.md)
- [dot product 📝](26_vector_and_tensor_operations_/03_dot_product_.md)
- [matrix multiplication (matmul) 📝](26_vector_and_tensor_operations_/04_matrix_multiplication_matmul_.md)
- [Matrix Vector Multiply `(m*v M v)` 📝](26_vector_and_tensor_operations_/05_matrix_vector_multiply_mv_m_v_.md)
- [Convolution 📝](26_vector_and_tensor_operations_/06_convolution_.md)

## Math Operations & Arithmetic ✅
- [Floating Point Precision ✅](27_math_operations_arithmetic_/01_floating_point_precision_.md)
- [Floating Point Only Operations ⚠️](27_math_operations_arithmetic_/02_floating_point_only_operations_.md)
- [Transcendental Functions ✅](27_math_operations_arithmetic_/03_transcendental_functions_.md)
- [Floating Point and Integer Operations ✅](27_math_operations_arithmetic_/04_floating_point_and_integer_operations_.md)
- [Integer Only Operations 📝](27_math_operations_arithmetic_/05_integer_only_operations_.md)
- [Integer Division ✅](27_math_operations_arithmetic_/06_integer_division_.md)
- [Hardware Supported Math Operations 📝](27_math_operations_arithmetic_/07_hardware_supported_math_operations_.md)

## Quantized Integers 📝
- [Quantized Integer Types 📝](28_quantized_integers_/01_quantized_integer_types_.md)

## Low Precision Floats ("microfloats") 📝
- [Format Wars](29_low_precision_floats_microfloats_/01_format_wars.md)
- [Micro Float Types 📝](29_low_precision_floats_microfloats_/02_micro_float_types_.md)
- [def-microfloat-block 📝](29_low_precision_floats_microfloats_/03_def_microfloat_block_.md)
- [blockwise operations 📝](29_low_precision_floats_microfloats_/04_blockwise_operations_.md)
- [Vector Conversion Operations 📝](29_low_precision_floats_microfloats_/05_vector_conversion_operations_.md)
- [element-wise access 📝](29_low_precision_floats_microfloats_/06_element_wise_access_.md)

## Complex Numbers 📝
- [soa-vector and complex 📝](30_complex_numbers_/01_soa_vector_and_complex_.md)

## Fast Fourier Transform (FFT) 📝

## Fused Softmax 📝

## Builtin GPU Functions ✅

## Forgotten 📝

## Strings - Compile Time and Run Time 📝
- [Compile Time Strings 📝](35_strings_compile_time_and_run_time_/01_compile_time_strings_.md)
- [Runtime Strings 📝](35_strings_compile_time_and_run_time_/02_runtime_strings_.md)

## Logging and Debugging 📝
- [Compile Time Output and Assert ✅](36_logging_and_debugging_/01_compile_time_output_and_assert_.md)
- [`(die "disaster")` ⚠️](36_logging_and_debugging_/02_die_disaster_.md)
- [Runtime Asserts ⚠️](36_logging_and_debugging_/03_runtime_asserts_.md)
- [Runtime Logging 📝](36_logging_and_debugging_/04_runtime_logging_.md)
- [Logging Utilities 📝](36_logging_and_debugging_/05_logging_utilities_.md)

## Debugging Implementation 📝
- [So You Want Debug Logging](37_debugging_implementation_/01_so_you_want_debug_logging.md)
- [Subdivide Subdivide Subdivide - the "other" debug flags](37_debugging_implementation_/02_subdivide_subdivide_subdivide_the_other_debug_flags.md)
- [Common Debug Flag Configurations 📝](37_debugging_implementation_/03_common_debug_flag_configurations_.md)

## Conditional Compilation ✅
- [defmacro ✅](38_conditional_compilation_/01_defmacro_.md)
- [target-has / device-has 📝](38_conditional_compilation_/02_target_has_device_has_.md)

## Assist defmacro Development 📝

## `entrypoint` 📝

## `defmacro` and `T`

## Static Analysys 📝
- [declaim ⚠️](42_static_analysys_/01_declaim_.md)
- [check-coalesce 📝](42_static_analysys_/02_check_coalesce_.md)
- [check-bank-conflicts 📝](42_static_analysys_/03_check_bank_conflicts_.md)
- [check-divergence 📝](42_static_analysys_/04_check_divergence_.md)
- [max-registers / warn-max-registers 📝](42_static_analysys_/05_max_registers_warn_max_registers_.md)
- [check-barriers 📝](42_static_analysys_/06_check_barriers_.md)
- [miscellaneous ⚠️](42_static_analysys_/07_miscellaneous_.md)

## Auto Differentiation (AD) ✅
- [`--differentiate` ✅](43_auto_differentiation_ad_/01__differentiate_.md)

## Foreign Function Interface (FFI) ✅
- [`def-foreign-function` ✅](44_foreign_function_interface_ffi_/01_def_foreign_function_.md)
- [pointers and handles: `c-pointer` ✅](44_foreign_function_interface_ffi_/02_pointers_and_handles_c_pointer_.md)
- [`base-ptr~` accessor ✅](44_foreign_function_interface_ffi_/03_base_ptr_accessor_.md)
- [handles ✅](44_foreign_function_interface_ffi_/04_handles_.md)
- [basic invocation ✅](44_foreign_function_interface_ffi_/05_basic_invocation_.md)
- [deferred invocation 📝](44_foreign_function_interface_ffi_/06_deferred_invocation_.md)

## Automatic Differentiation over the FFI Boundary
- [The VJP Signature Rule (vetted)](45_automatic_differentiation_over_the_ffi_boundary/01_the_vjp_signature_rule_vetted.md)
- [Signature mapping examples](45_automatic_differentiation_over_the_ffi_boundary/02_signature_mapping_examples.md)
- [Example 1 — A transcendental, no buffers](45_automatic_differentiation_over_the_ffi_boundary/03_example_1_a_transcendental_no_buffers.md)
- [Example 2 — A buffer op with shadow accumulation (the aggressive case)](45_automatic_differentiation_over_the_ffi_boundary/04_example_2_a_buffer_op_with_shadow_accumulation_the_aggressive_case.md)

## Hoisting and `def-orchestration` ⚠️
- [`def-orchestration` 📝](46_hoisting_and_def_orchestration_/01_def_orchestration_.md)
- [launch-sequential 📝](46_hoisting_and_def_orchestration_/02_launch_sequential_.md)
- [launch-kernel 📝](46_hoisting_and_def_orchestration_/03_launch_kernel_.md)
- [launch-parallel 📝](46_hoisting_and_def_orchestration_/04_launch_parallel_.md)

## Compiler Invocation and Options ✅
- [Output Targeting Options 📝](47_compiler_invocation_and_options_/01_output_targeting_options_.md)
- [Other Flags ⚠️](47_compiler_invocation_and_options_/02_other_flags_.md)
- [Compiliation Flags ✅](47_compiler_invocation_and_options_/03_compiliation_flags_.md)
- [Fast Compilation ✅](47_compiler_invocation_and_options_/04_fast_compilation_.md)
- [Compiler Invocations and Files ✅](47_compiler_invocation_and_options_/05_compiler_invocations_and_files_.md)

## Hoisting Code ✅

## In-Memory Compilation API 📝
- [C API 📝](49_in_memory_compilation_api_/01_c_api_.md)
- [Status Codes ✅](49_in_memory_compilation_api_/02_status_codes_.md)
- [Flags](49_in_memory_compilation_api_/03_flags.md)

## APPENDIX #1 - Summary: set / get vars, storage handles, and structs

## APPENDIX #2 - Math with Quantized Ints and Microfloat
- [dot product and matmul 📝](51_appendix_2_math_with_quantized_ints_and_microfloat/01_dot_product_and_matmul_.md)

## Acknowledgements ✅

## INDECES
- [def-](53_indeces/01_def_.md)
- [control flow](53_indeces/02_control_flow.md)
- [Higher Order Function Operations](53_indeces/03_higher_order_function_operations.md)
- [Sorting](53_indeces/04_sorting.md)
- [Algorithms](53_indeces/05_algorithms.md)
- [Atomics](53_indeces/06_atomics.md)
- [Type Constraints](53_indeces/07_type_constraints.md)
- [other](53_indeces/08_other.md)
- [Hardware Operations](53_indeces/09_hardware_operations.md)
- [logging and debugging](53_indeces/10_logging_and_debugging.md)
- [static analysis](53_indeces/11_static_analysis.md)
- [hoisting and def-orchestration](53_indeces/12_hoisting_and_def_orchestration.md)
- [lisp](53_indeces/13_lisp.md)
- [To Do](53_indeces/14_to_do.md)
- [Memory](53_indeces/15_memory.md)
