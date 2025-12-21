# Crisp Language Specification


## CRISP - Lisp for developing GPU Kernels
- [Overview](chapters/01_crisp_lisp_for_developing_gpu_kernels/01_overview.md)
- [Focus](chapters/01_crisp_lisp_for_developing_gpu_kernels/02_focus.md)
- [Major Features of the Crisp language and tools](chapters/01_crisp_lisp_for_developing_gpu_kernels/03_major_features_of_the_crisp_language_and_tools.md)
- [Differences From Lisp](chapters/01_crisp_lisp_for_developing_gpu_kernels/04_differences_from_lisp.md)
- [Commonalities with C++](chapters/01_crisp_lisp_for_developing_gpu_kernels/05_commonalities_with_c.md)

## Table of Contents

## Thread Level / Grid Level / Dispatch
- [Why This is Different from C++/CUDA](chapters/03_thread_level_grid_level_dispatch/01_why_this_is_different_from_ccuda.md)

## Terminology: Storage Handles

## Top Level Execution Constructs
- [`def-kernel`](chapters/05_top_level_execution_constructs/01_def_kernel.md)
- [`def-function`](chapters/05_top_level_execution_constructs/02_def_function.md)
- [`def-grid-function`](chapters/05_top_level_execution_constructs/03_def_grid_function.md)

## Return Storage Handle Pattern `&out`

## Argument Passing and Side Channels

## Crisp Types
- [Base Numeric Types](chapters/08_crisp_types/01_base_numeric_types.md)
- [Vector Numeric Types](chapters/08_crisp_types/02_vector_numeric_types.md)
- [Numeric Type Promotion, Casting, Conversion](chapters/08_crisp_types/03_numeric_type_promotion_casting_conversion.md)
- [Quantized Integers and Complex Numbers](chapters/08_crisp_types/04_quantized_integers_and_complex_numbers.md)
- [Other Basic Types](chapters/08_crisp_types/05_other_basic_types.md)
- [Declaring Types - Functions](chapters/08_crisp_types/06_declaring_types_functions.md)
- [Function Overloading](chapters/08_crisp_types/07_function_overloading.md)
- [Recursion Disallowed](chapters/08_crisp_types/08_recursion_disallowed.md)
- [Declaring Types - Kernels](chapters/08_crisp_types/09_declaring_types_kernels.md)
- [Struct Types](chapters/08_crisp_types/10_struct_types.md)
- [def-setter](chapters/08_crisp_types/11_def_setter.md)
- [Template Types](chapters/08_crisp_types/12_template_types.md)
- [def-constraint](chapters/08_crisp_types/13_def_constraint.md)
- [def-type-function](chapters/08_crisp_types/14_def_type_function.md)

## GPU Memory

## Storage Handle Types
- [Storage Properties](chapters/10_storage_handle_types/01_storage_properties.md)
- [Cell Properties](chapters/10_storage_handle_types/02_cell_properties.md)
- [Vector / Matrix /Tensor Properties](chapters/10_storage_handle_types/03_vector_matrix_tensor_properties.md)
- [Element Access](chapters/10_storage_handle_types/04_element_access.md)
- [Helper Functions](chapters/10_storage_handle_types/05_helper_functions.md)
- [Member Data Rules](chapters/10_storage_handle_types/06_member_data_rules.md)
- [Storage Handle Type Definitions](chapters/10_storage_handle_types/07_storage_handle_type_definitions.md)
- [Storage Handle Arguments for Kernels](chapters/10_storage_handle_types/08_storage_handle_arguments_for_kernels.md)
- [Creating Storage Handle Views](chapters/10_storage_handle_types/09_creating_storage_handle_views.md)
- [Reduce Boilerplate: `in-XXXX` and `out-XXXX`](chapters/10_storage_handle_types/10_reduce_boilerplate_in_xxxx_and_out_xxxx.md)
- [soa-vector](chapters/10_storage_handle_types/11_soa_vector.md)
- [def-const](chapters/10_storage_handle_types/12_def_const.md)
- [def-parameter](chapters/10_storage_handle_types/13_def_parameter.md)
- [def-const-vec](chapters/10_storage_handle_types/14_def_const_vec.md)
- [Side Channel Storage Handles](chapters/10_storage_handle_types/15_side_channel_storage_handles.md)
- [Async Memory Operations](chapters/10_storage_handle_types/16_async_memory_operations.md)
- [Tensors & Matrices](chapters/10_storage_handle_types/17_tensors_matrices.md)
- [Matrices](chapters/10_storage_handle_types/18_matrices.md)
- [Type Aliases and Type Constructors](chapters/10_storage_handle_types/19_type_aliases_and_type_constructors.md)
- [Derived Types](chapters/10_storage_handle_types/20_derived_types.md)
- [Continuation Kernels](chapters/10_storage_handle_types/21_continuation_kernels.md)
- [First Order Functions](chapters/10_storage_handle_types/22_first_order_functions.md)
- [No First Order Types](chapters/10_storage_handle_types/23_no_first_order_types.md)
- [Enumerations](chapters/10_storage_handle_types/24_enumerations.md)
- [Maybe Type](chapters/10_storage_handle_types/25_maybe_type.md)

## `let`

## `set!`

## `declare`
- [`declare` and templates](chapters/13_declare/01_declare_and_templates.md)
- [Other `declare` directives](chapters/13_declare/02_other_declare_directives.md)
- [For `defmacro` writers](chapters/13_declare/03_for_defmacro_writers.md)
- [For Static Analysis](chapters/13_declare/04_for_static_analysis.md)

## Control Flow
- [Single Task](chapters/14_control_flow/01_single_task.md)
- [when-thread-is / abs-when-thread-is](chapters/14_control_flow/02_when_thread_is_abs_when_thread_is.md)
- [when-thread-in-group-is / when-group-is](chapters/14_control_flow/03_when_thread_in_group_is_when_group_is.md)
- [when-global-linear-id-is / when-local-linear-id-is](chapters/14_control_flow/04_when_global_linear_id_is_when_local_linear_id_is.md)
- [when-is-last-workgroup](chapters/14_control_flow/05_when_is_last_workgroup.md)
- [when-is-last-warp / when-is-last-thread](chapters/14_control_flow/06_when_is_last_warp_when_is_last_thread.md)
- [Hoisting and Enqueing a Kernel](chapters/14_control_flow/07_hoisting_and_enqueing_a_kernel.md)
- [Latency Hiding - warp sizes and workgroup sizes](chapters/14_control_flow/08_latency_hiding_warp_sizes_and_workgroup_sizes.md)
- [One Thread Per Element](chapters/14_control_flow/09_one_thread_per_element.md)
- [Looping - Grid Stride](chapters/14_control_flow/10_looping_grid_stride.md)
- [General Purpose: `thread-stride`](chapters/14_control_flow/11_general_purpose_thread_stride.md)
- [Load Chunk / Store Chunk](chapters/14_control_flow/12_load_chunk_store_chunk.md)
- [Workgroup Stride](chapters/14_control_flow/13_workgroup_stride.md)
- [Looping -- Uniform Loops](chapters/14_control_flow/14_looping_uniform_loops.md)
- [Looping Constructs](chapters/14_control_flow/15_looping_constructs.md)
- [Grid Level Operations](chapters/14_control_flow/16_grid_level_operations.md)
- [Workgroup Level Operations](chapters/14_control_flow/17_workgroup_level_operations.md)
- [Barriers and Fences](chapters/14_control_flow/18_barriers_and_fences.md)
- [Sum a Vector using Local Memory](chapters/14_control_flow/19_sum_a_vector_using_local_memory.md)
- [Warps & Shuffles](chapters/14_control_flow/20_warps_shuffles.md)
- [Sum a Vector using Warps and Shuffles](chapters/14_control_flow/21_sum_a_vector_using_warps_and_shuffles.md)

## Bit Twiddling Operations
- [`op-popcount`](chapters/15_bit_twiddling_operations/01_op_popcount.md)
- [`op-count-leading-zeros` / `op-count-trailing-zeros`](chapters/15_bit_twiddling_operations/02_op_count_leading_zeros_op_count_trailing_zeros.md)
- [`op-find-msb` / `op-find-lsb`](chapters/15_bit_twiddling_operations/03_op_find_msb_op_find_lsb.md)
- [`op-bit-reverse`](chapters/15_bit_twiddling_operations/04_op_bit_reverse.md)
- [`op-bitfield-extract` / `op-bitfield-insert`](chapters/15_bit_twiddling_operations/05_op_bitfield_extract_op_bitfield_insert.md)

## Hardware Bit Packing / Unpacking
- [`op-pack-11` / `op-unpack-11`](chapters/16_hardware_bit_packing_unpacking/01_op_pack_11_op_unpack_11.md)
- [`op-pack-half-2x16` / `op-unpack-half-2x16`](chapters/16_hardware_bit_packing_unpacking/02_op_pack_half_2x16_op_unpack_half_2x16.md)
- [`op-pack-unorm-4x8` / `op-unpack-unorm-4x8`](chapters/16_hardware_bit_packing_unpacking/03_op_pack_unorm_4x8_op_unpack_unorm_4x8.md)
- [`op-pack-snorm-4x8` / `op-unpack-snorm-4x8`](chapters/16_hardware_bit_packing_unpacking/04_op_pack_snorm_4x8_op_unpack_snorm_4x8.md)
- [`op-pack-unorm-2x16` / `op-unpack-unorm-2x16`](chapters/16_hardware_bit_packing_unpacking/05_op_pack_unorm_2x16_op_unpack_unorm_2x16.md)
- [`op-pack-double-2x32` / `op-unpack-double-2x32`](chapters/16_hardware_bit_packing_unpacking/06_op_pack_double_2x32_op_unpack_double_2x32.md)
- [`op-pack-rgb-9e5` (Shared Exponent)  Pack only.](chapters/16_hardware_bit_packing_unpacking/07_op_pack_rgb_9e5_shared_exponent_pack_only.md)

## Branching
- [Cost of Divergent Branching](chapters/17_branching/01_cost_of_divergent_branching.md)
- [Predicated Selection](chapters/17_branching/02_predicated_selection.md)

## Higher Order Function Operations
- [Compile Time Resolution](chapters/18_higher_order_function_operations/01_compile_time_resolution.md)
- [Lambda No, Curry Yes](chapters/18_higher_order_function_operations/02_lambda_no_curry_yes.md)
- [map](chapters/18_higher_order_function_operations/03_map.md)
- [Invoking Functions: `funcall`](chapters/18_higher_order_function_operations/04_invoking_functions_funcall.md)

## Shop Local, Act Global

## Reduce Variants
- [reduce vector](chapters/20_reduce_variants/01_reduce_vector.md)

## Boolean Reductions
- [`all?` / `none?`](chapters/21_boolean_reductions/01_all_none.md)
- [`any?`](chapters/21_boolean_reductions/02_any.md)

## Segmented Reduction

## Filtering / Prefix-Sum Scan
- [`prepare-for-scan--value`](chapters/23_filtering_prefix_sum_scan/01_prepare_for_scan_value.md)
- [`prepare-for-scan--index`](chapters/23_filtering_prefix_sum_scan/02_prepare_for_scan_index.md)
- [`exclusive-scan-workgroup`](chapters/23_filtering_prefix_sum_scan/03_exclusive_scan_workgroup.md)
- [`inclusive-scan-workgroup`](chapters/23_filtering_prefix_sum_scan/04_inclusive_scan_workgroup.md)
- [global-exclusive-scan](chapters/23_filtering_prefix_sum_scan/05_global_exclusive_scan.md)
- [global-inclusive-scan](chapters/23_filtering_prefix_sum_scan/06_global_inclusive_scan.md)
- [Word Count With Exclusive Scan](chapters/23_filtering_prefix_sum_scan/07_word_count_with_exclusive_scan.md)
- [`filter`](chapters/23_filtering_prefix_sum_scan/08_filter.md)

## Gather / Scatter

## Sorting
- [Bitonic Sort](chapters/25_sorting/01_bitonic_sort.md)
- [Radix Sort](chapters/25_sorting/02_radix_sort.md)

## Atomics
- [Atomic Operations](chapters/26_atomics/01_atomic_operations.md)

## Vector and Tensor Operations
- [`fill` and `iota`](chapters/27_vector_and_tensor_operations/01_fill_and_iota.md)
- [`copy`](chapters/27_vector_and_tensor_operations/02_copy.md)
- [dot product](chapters/27_vector_and_tensor_operations/03_dot_product.md)
- [matrix multiplication (matmul)](chapters/27_vector_and_tensor_operations/04_matrix_multiplication_matmul.md)
- [Matrix Vector Multiply `(m*v M v)`](chapters/27_vector_and_tensor_operations/05_matrix_vector_multiply_mv_m_v.md)
- [Convolution](chapters/27_vector_and_tensor_operations/06_convolution.md)

## Math Operations & Arithmetic
- [Floating Point Precision](chapters/28_math_operations_arithmetic/01_floating_point_precision.md)
- [Floating Point Only Operations](chapters/28_math_operations_arithmetic/02_floating_point_only_operations.md)
- [Floating Point and Integer Operations](chapters/28_math_operations_arithmetic/03_floating_point_and_integer_operations.md)
- [Integer Only Operations](chapters/28_math_operations_arithmetic/04_integer_only_operations.md)
- [Integer Division](chapters/28_math_operations_arithmetic/05_integer_division.md)
- [Hardware Supported Math Operations](chapters/28_math_operations_arithmetic/06_hardware_supported_math_operations.md)

## Quantized Integers
- [Quantized Integer Types](chapters/29_quantized_integers/01_quantized_integer_types.md)

## Low Precision Floats ("microfloats")
- [Format Wars](chapters/30_low_precision_floats_microfloats/01_format_wars.md)
- [Micro Float Types](chapters/30_low_precision_floats_microfloats/02_micro_float_types.md)
- [def-microfloat-block](chapters/30_low_precision_floats_microfloats/03_def_microfloat_block.md)
- [blockwise operations](chapters/30_low_precision_floats_microfloats/04_blockwise_operations.md)
- [Vector Conversion Operations](chapters/30_low_precision_floats_microfloats/05_vector_conversion_operations.md)
- [element-wise access](chapters/30_low_precision_floats_microfloats/06_element_wise_access.md)

## Complex Numbers
- [soa-vector and complex](chapters/31_complex_numbers/01_soa_vector_and_complex.md)

## Fast Fourier Transform (FFT)

## Fused Softmax

## Builtin GPU Functions & Constants

## Forgotten

## Strings - Compile Time and Run Time
- [Compile Time Strings](chapters/36_strings_compile_time_and_run_time/01_compile_time_strings.md)
- [Runtime Strings](chapters/36_strings_compile_time_and_run_time/02_runtime_strings.md)

## Logging and Debugging
- [Compile Time Output and Assert](chapters/37_logging_and_debugging/01_compile_time_output_and_assert.md)
- [`(die "disaster")`](chapters/37_logging_and_debugging/02_die_disaster.md)
- [Runtime Asserts](chapters/37_logging_and_debugging/03_runtime_asserts.md)
- [Runtime Logging](chapters/37_logging_and_debugging/04_runtime_logging.md)
- [Logging Utilities](chapters/37_logging_and_debugging/05_logging_utilities.md)

## Debugging Implementation
- [So You Want Debug Logging](chapters/38_debugging_implementation/01_so_you_want_debug_logging.md)
- [Subdivide Subdivide Subdivide - the "other" debug flags](chapters/38_debugging_implementation/02_subdivide_subdivide_subdivide_the_other_debug_flags.md)
- [Common Debug Flag Configurations](chapters/38_debugging_implementation/03_common_debug_flag_configurations.md)

## Conditional Compilation
- [defmacro](chapters/39_conditional_compilation/01_defmacro.md)
- [target-has / device-has](chapters/39_conditional_compilation/02_target_has_device_has.md)

## Assist defmacro Development

## `entrypoint`

## Static Analysys
- [declaim](chapters/42_static_analysys/01_declaim.md)
- [check-coalesce](chapters/42_static_analysys/02_check_coalesce.md)
- [check-bank-conflicts](chapters/42_static_analysys/03_check_bank_conflicts.md)
- [check-divergence](chapters/42_static_analysys/04_check_divergence.md)
- [max-registers / warn-max-registers](chapters/42_static_analysys/05_max_registers_warn_max_registers.md)
- [check-barriers](chapters/42_static_analysys/06_check_barriers.md)
- [miscellaneous](chapters/42_static_analysys/07_miscellaneous.md)

## Hoisting and `def-orchestration`
- [`def-orchestration`](chapters/43_hoisting_and_def_orchestration/01_def_orchestration.md)
- [launch-sequential](chapters/43_hoisting_and_def_orchestration/02_launch_sequential.md)
- [launch-kernel](chapters/43_hoisting_and_def_orchestration/03_launch_kernel.md)
- [launch-parallel](chapters/43_hoisting_and_def_orchestration/04_launch_parallel.md)
- [launch-interleaved](chapters/43_hoisting_and_def_orchestration/05_launch_interleaved.md)

## Compiler Invocation and Options
- [Output Targeting Options](chapters/44_compiler_invocation_and_options/01_output_targeting_options.md)
- [Other Flags](chapters/44_compiler_invocation_and_options/02_other_flags.md)
- [Compiliation Flags](chapters/44_compiler_invocation_and_options/03_compiliation_flags.md)
- [Fast Compilation](chapters/44_compiler_invocation_and_options/04_fast_compilation.md)

## Hoisting Code

## In-Memory Compilation API
- [C API](chapters/46_in_memory_compilation_api/01_c_api.md)
- [Status Codes](chapters/46_in_memory_compilation_api/02_status_codes.md)
- [Flags](chapters/46_in_memory_compilation_api/03_flags.md)

## APPENDIX #1 - Summary: set / get vars, storage handles, and structs

## APPENDIX #2 - Math with Quantized Ints and Microfloat
- [dot product and matmul](chapters/48_appendix_2_math_with_quantized_ints_and_microfloat/01_dot_product_and_matmul.md)

## INDECES
- [def-](chapters/49_indeces/01_def_.md)
- [control flow](chapters/49_indeces/02_control_flow.md)
- [Higher Order Function Operations](chapters/49_indeces/03_higher_order_function_operations.md)
- [Sorting](chapters/49_indeces/04_sorting.md)
- [Algorithms](chapters/49_indeces/05_algorithms.md)
- [Atomics](chapters/49_indeces/06_atomics.md)
- [Type Constraints](chapters/49_indeces/07_type_constraints.md)
- [other](chapters/49_indeces/08_other.md)
- [Hardware Operations](chapters/49_indeces/09_hardware_operations.md)
- [logging and debugging](chapters/49_indeces/10_logging_and_debugging.md)
- [static analysis](chapters/49_indeces/11_static_analysis.md)
- [hoisting and def-orchestration](chapters/49_indeces/12_hoisting_and_def_orchestration.md)
- [lisp](chapters/49_indeces/13_lisp.md)
- [To Do](chapters/49_indeces/14_to_do.md)
- [Memory](chapters/49_indeces/15_memory.md)
