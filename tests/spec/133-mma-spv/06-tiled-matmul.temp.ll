; ModuleID = '06-tiled-matmul'
source_filename = "06-tiled-matmul"
target triple = "spir64-unknown-unknown"

%S_06_tiled_matmul_STORAGE_GLOBAL = type { ptr addrspace(1), i64 }
%S_06_tiled_matmul_CELL_INT_GLOBAL = type { %S_06_tiled_matmul_STORAGE_GLOBAL, i64 }
%S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST = type { %S_06_tiled_matmul_STORAGE_GLOBAL, [2 x i64], [2 x i64], [2 x i64], i64 }
%S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST = type { %S_06_tiled_matmul_STORAGE_GLOBAL, [2 x i64], [2 x i64], [2 x i64], i64 }
%S_06_tiled_matmul_STORAGE_LOCAL = type { ptr addrspace(3), i64 }
%S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST = type { %S_06_tiled_matmul_STORAGE_LOCAL, [2 x i64], [2 x i64], [2 x i64], i64 }
%S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 = type { float, float, float, float }
%S_06_tiled_matmul_REGISTER-FRAGMENT-A-TF32-16X8 = type { float, float, float, float }
%S_06_tiled_matmul_REGISTER-FRAGMENT-B-TF32-8X8 = type { float, float }

@__spirv_BuiltInLocalInvocationId = addrspace(1) global <3 x i64> zeroinitializer
@__spirv_BuiltInWorkgroupSize = addrspace(1) global <3 x i64> zeroinitializer
@__spirv_BuiltInSubgroupLocalInvocationId = addrspace(1) global i32 0

define spir_func ptr addrspace(1) @address__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_06_tiled_matmul_STORAGE_GLOBAL, align 8
  store %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_06_tiled_matmul_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_06_tiled_matmul_STORAGE_GLOBAL %obj1, 0
  ret ptr addrspace(1) %extract_0
}

define spir_func i64 @byte_size__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_06_tiled_matmul_STORAGE_GLOBAL, align 8
  store %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_06_tiled_matmul_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_06_tiled_matmul_STORAGE_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func i32 @address_space__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_06_tiled_matmul_STORAGE_GLOBAL, align 8
  store %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func ptr addrspace(1) @_address__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_06_tiled_matmul_STORAGE_GLOBAL, align 8
  store %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_06_tiled_matmul_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_06_tiled_matmul_STORAGE_GLOBAL %obj1, 0
  ret ptr addrspace(1) %extract_0
}

define spir_func i64 @_byte_size__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_06_tiled_matmul_STORAGE_GLOBAL, align 8
  store %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_06_tiled_matmul_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_06_tiled_matmul_STORAGE_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func %S_06_tiled_matmul_STORAGE_GLOBAL @parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_CELL_INT_GLOBAL undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_06_tiled_matmul_CELL_INT_GLOBAL, align 8
  store %S_06_tiled_matmul_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_06_tiled_matmul_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_06_tiled_matmul_CELL_INT_GLOBAL %obj1, 0
  ret %S_06_tiled_matmul_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @offset__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_CELL_INT_GLOBAL undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_06_tiled_matmul_CELL_INT_GLOBAL, align 8
  store %S_06_tiled_matmul_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_06_tiled_matmul_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_06_tiled_matmul_CELL_INT_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func i32 @address_space__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_CELL_INT_GLOBAL undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_06_tiled_matmul_CELL_INT_GLOBAL, align 8
  store %S_06_tiled_matmul_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func %S_06_tiled_matmul_STORAGE_GLOBAL @_parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_CELL_INT_GLOBAL undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_06_tiled_matmul_CELL_INT_GLOBAL, align 8
  store %S_06_tiled_matmul_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_06_tiled_matmul_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_06_tiled_matmul_CELL_INT_GLOBAL %obj1, 0
  ret %S_06_tiled_matmul_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @_offset__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_CELL_INT_GLOBAL undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_06_tiled_matmul_CELL_INT_GLOBAL, align 8
  store %S_06_tiled_matmul_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_06_tiled_matmul_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_06_tiled_matmul_CELL_INT_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func %S_06_tiled_matmul_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 0
  ret %S_06_tiled_matmul_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @length__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 4
  ret i64 %extract_4
}

define spir_func i64 @num_dims__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i64 2
}

define spir_func i32 @address_space__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func i32 @align__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func i32 @contiguous_term__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func %S_06_tiled_matmul_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 0
  ret %S_06_tiled_matmul_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @_length__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 4
  ret i64 %extract_4
}

define spir_func %S_06_tiled_matmul_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_0 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 0
  ret %S_06_tiled_matmul_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @length__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_4 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 4
  ret i64 %extract_4
}

define spir_func i64 @num_dims__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i64 2
}

define spir_func i32 @address_space__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func i32 @align__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func i32 @contiguous_term__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func %S_06_tiled_matmul_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_0 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 0
  ret %S_06_tiled_matmul_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @_length__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_4 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 4
  ret i64 %extract_4
}

define spir_func ptr addrspace(3) @address__storage_local(ptr addrspace(3) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_06_tiled_matmul_STORAGE_LOCAL, align 8
  store %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_06_tiled_matmul_STORAGE_LOCAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %obj1, 0
  ret ptr addrspace(3) %extract_0
}

define spir_func i64 @byte_size__storage_local(ptr addrspace(3) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_06_tiled_matmul_STORAGE_LOCAL, align 8
  store %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_06_tiled_matmul_STORAGE_LOCAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %obj1, 1
  ret i64 %extract_1
}

define spir_func i32 @address_space__storage_local(ptr addrspace(3) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_06_tiled_matmul_STORAGE_LOCAL, align 8
  store %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, ptr %obj, align 8
  ret i32 3
}

define spir_func ptr addrspace(3) @_address__storage_local(ptr addrspace(3) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_06_tiled_matmul_STORAGE_LOCAL, align 8
  store %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_06_tiled_matmul_STORAGE_LOCAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %obj1, 0
  ret ptr addrspace(3) %extract_0
}

define spir_func i64 @_byte_size__storage_local(ptr addrspace(3) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_06_tiled_matmul_STORAGE_LOCAL, align 8
  store %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_06_tiled_matmul_STORAGE_LOCAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %obj1, 1
  ret i64 %extract_1
}

define spir_func %S_06_tiled_matmul_STORAGE_LOCAL @parent__tensor_float_2_local_compact_last(ptr addrspace(3) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %obj5, 0
  ret %S_06_tiled_matmul_STORAGE_LOCAL %extract_0
}

define spir_func i64 @length__tensor_float_2_local_compact_last(ptr addrspace(3) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %obj5, 4
  ret i64 %extract_4
}

define spir_func i64 @num_dims__tensor_float_2_local_compact_last(ptr addrspace(3) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i64 2
}

define spir_func i32 @address_space__tensor_float_2_local_compact_last(ptr addrspace(3) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 3
}

define spir_func i32 @align__tensor_float_2_local_compact_last(ptr addrspace(3) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func i32 @contiguous_term__tensor_float_2_local_compact_last(ptr addrspace(3) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func %S_06_tiled_matmul_STORAGE_LOCAL @_parent__tensor_float_2_local_compact_last(ptr addrspace(3) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %obj5, 0
  ret %S_06_tiled_matmul_STORAGE_LOCAL %extract_0
}

define spir_func i64 @_length__tensor_float_2_local_compact_last(ptr addrspace(3) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %obj5, 4
  ret i64 %extract_4
}

define spir_kernel void @tiled_matmul(ptr addrspace(3) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8, ptr addrspace(3) %9, i64 %10, i64 %11, i64 %12, i64 %13, i64 %14, i64 %15, i64 %16, i64 %17, ptr addrspace(1) %18, i64 %19, i64 %20, i64 %21, i64 %22, i64 %23, i64 %24, i64 %25, i64 %26, ptr addrspace(1) %27, i64 %28, i64 %29, i64 %30, i64 %31, i64 %32, i64 %33, i64 %34, i64 %35, ptr addrspace(1) %36, i64 %37, i64 %38, i64 %39, i64 %40, i64 %41, i64 %42, i64 %43, i64 %44) !kernel_arg_addr_space !100 !kernel_arg_access_qual !101 !kernel_arg_type !102 !kernel_arg_base_type !103 !kernel_arg_type_qual !104 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %b-tile_from_tiled_matmul_2 = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %LENGTH_ins, ptr %b-tile_from_tiled_matmul_2, align 8
  %ADDRESS_ins5 = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %9, 0
  %BYTE-SIZE_ins6 = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins5, i64 %10, 1
  %PARENT_ins7 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins6, 0
  %arr_build_08 = insertvalue [2 x i64] undef, i64 %11, 0
  %arr_build_19 = insertvalue [2 x i64] %arr_build_08, i64 %12, 1
  %OFFSET_ins10 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %PARENT_ins7, [2 x i64] %arr_build_19, 1
  %arr_build_011 = insertvalue [2 x i64] undef, i64 %13, 0
  %arr_build_112 = insertvalue [2 x i64] %arr_build_011, i64 %14, 1
  %STRIDES_ins13 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %OFFSET_ins10, [2 x i64] %arr_build_112, 2
  %arr_build_014 = insertvalue [2 x i64] undef, i64 %15, 0
  %arr_build_115 = insertvalue [2 x i64] %arr_build_014, i64 %16, 1
  %EXTENTS_ins16 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %STRIDES_ins13, [2 x i64] %arr_build_115, 3
  %LENGTH_ins17 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %EXTENTS_ins16, i64 %17, 4
  %a-tile_from_tiled_matmul_1 = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %LENGTH_ins17, ptr %a-tile_from_tiled_matmul_1, align 8
  %a_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %18, ptr %a_ptr, align 8
  %a_byte_size = alloca i64, align 8
  store i64 %19, ptr %a_byte_size, align 4
  %a_offset_0 = alloca i64, align 8
  store i64 %20, ptr %a_offset_0, align 4
  %a_offset_1 = alloca i64, align 8
  store i64 %21, ptr %a_offset_1, align 4
  %a_stride_0 = alloca i64, align 8
  store i64 %22, ptr %a_stride_0, align 4
  %a_stride_1 = alloca i64, align 8
  store i64 %23, ptr %a_stride_1, align 4
  %a_extent_0 = alloca i64, align 8
  store i64 %24, ptr %a_extent_0, align 4
  %a_extent_1 = alloca i64, align 8
  store i64 %25, ptr %a_extent_1, align 4
  %a_length = alloca i64, align 8
  store i64 %26, ptr %a_length, align 4
  %b_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %27, ptr %b_ptr, align 8
  %b_byte_size = alloca i64, align 8
  store i64 %28, ptr %b_byte_size, align 4
  %b_offset_0 = alloca i64, align 8
  store i64 %29, ptr %b_offset_0, align 4
  %b_offset_1 = alloca i64, align 8
  store i64 %30, ptr %b_offset_1, align 4
  %b_stride_0 = alloca i64, align 8
  store i64 %31, ptr %b_stride_0, align 4
  %b_stride_1 = alloca i64, align 8
  store i64 %32, ptr %b_stride_1, align 4
  %b_extent_0 = alloca i64, align 8
  store i64 %33, ptr %b_extent_0, align 4
  %b_extent_1 = alloca i64, align 8
  store i64 %34, ptr %b_extent_1, align 4
  %b_length = alloca i64, align 8
  store i64 %35, ptr %b_length, align 4
  %c_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %36, ptr %c_ptr, align 8
  %c_byte_size = alloca i64, align 8
  store i64 %37, ptr %c_byte_size, align 4
  %c_offset_0 = alloca i64, align 8
  store i64 %38, ptr %c_offset_0, align 4
  %c_offset_1 = alloca i64, align 8
  store i64 %39, ptr %c_offset_1, align 4
  %c_stride_0 = alloca i64, align 8
  store i64 %40, ptr %c_stride_0, align 4
  %c_stride_1 = alloca i64, align 8
  store i64 %41, ptr %c_stride_1, align 4
  %c_extent_0 = alloca i64, align 8
  store i64 %42, ptr %c_extent_0, align 4
  %c_extent_1 = alloca i64, align 8
  store i64 %43, ptr %c_extent_1, align 4
  %c_length = alloca i64, align 8
  store i64 %44, ptr %c_length, align 4
  %a_ptr18 = load ptr addrspace(1), ptr %a_ptr, align 8
  %insert_ADDRESS = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %a_ptr18, 0
  %a_byte_size19 = load i64, ptr %a_byte_size, align 4
  %insert_BYTE-SIZE = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %insert_ADDRESS, i64 %a_byte_size19, 1
  %insert_PARENT = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %insert_BYTE-SIZE, 0
  %a_offset_020 = load i64, ptr %a_offset_0, align 4
  %arr_ins_0 = insertvalue [2 x i64] undef, i64 %a_offset_020, 0
  %a_offset_121 = load i64, ptr %a_offset_1, align 4
  %arr_ins_1 = insertvalue [2 x i64] %arr_ins_0, i64 %a_offset_121, 1
  %insert_OFFSET = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_PARENT, [2 x i64] %arr_ins_1, 1
  %a_stride_022 = load i64, ptr %a_stride_0, align 4
  %arr_ins_023 = insertvalue [2 x i64] undef, i64 %a_stride_022, 0
  %a_stride_124 = load i64, ptr %a_stride_1, align 4
  %arr_ins_125 = insertvalue [2 x i64] %arr_ins_023, i64 %a_stride_124, 1
  %insert_STRIDES = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_OFFSET, [2 x i64] %arr_ins_125, 2
  %a_extent_026 = load i64, ptr %a_extent_0, align 4
  %arr_ins_027 = insertvalue [2 x i64] undef, i64 %a_extent_026, 0
  %a_extent_128 = load i64, ptr %a_extent_1, align 4
  %arr_ins_129 = insertvalue [2 x i64] %arr_ins_027, i64 %a_extent_128, 1
  %insert_EXTENTS = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_STRIDES, [2 x i64] %arr_ins_129, 3
  %a_length30 = load i64, ptr %a_length, align 4
  %insert_LENGTH = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_EXTENTS, i64 %a_length30, 4
  %a = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_LENGTH, ptr %a, align 8
  %b_ptr31 = load ptr addrspace(1), ptr %b_ptr, align 8
  %insert_ADDRESS32 = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %b_ptr31, 0
  %b_byte_size33 = load i64, ptr %b_byte_size, align 4
  %insert_BYTE-SIZE34 = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %insert_ADDRESS32, i64 %b_byte_size33, 1
  %insert_PARENT35 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %insert_BYTE-SIZE34, 0
  %b_offset_036 = load i64, ptr %b_offset_0, align 4
  %arr_ins_037 = insertvalue [2 x i64] undef, i64 %b_offset_036, 0
  %b_offset_138 = load i64, ptr %b_offset_1, align 4
  %arr_ins_139 = insertvalue [2 x i64] %arr_ins_037, i64 %b_offset_138, 1
  %insert_OFFSET40 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_PARENT35, [2 x i64] %arr_ins_139, 1
  %b_stride_041 = load i64, ptr %b_stride_0, align 4
  %arr_ins_042 = insertvalue [2 x i64] undef, i64 %b_stride_041, 0
  %b_stride_143 = load i64, ptr %b_stride_1, align 4
  %arr_ins_144 = insertvalue [2 x i64] %arr_ins_042, i64 %b_stride_143, 1
  %insert_STRIDES45 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_OFFSET40, [2 x i64] %arr_ins_144, 2
  %b_extent_046 = load i64, ptr %b_extent_0, align 4
  %arr_ins_047 = insertvalue [2 x i64] undef, i64 %b_extent_046, 0
  %b_extent_148 = load i64, ptr %b_extent_1, align 4
  %arr_ins_149 = insertvalue [2 x i64] %arr_ins_047, i64 %b_extent_148, 1
  %insert_EXTENTS50 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_STRIDES45, [2 x i64] %arr_ins_149, 3
  %b_length51 = load i64, ptr %b_length, align 4
  %insert_LENGTH52 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_EXTENTS50, i64 %b_length51, 4
  %b = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_LENGTH52, ptr %b, align 8
  %c_ptr53 = load ptr addrspace(1), ptr %c_ptr, align 8
  %insert_ADDRESS54 = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %c_ptr53, 0
  %c_byte_size55 = load i64, ptr %c_byte_size, align 4
  %insert_BYTE-SIZE56 = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %insert_ADDRESS54, i64 %c_byte_size55, 1
  %insert_PARENT57 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_06_tiled_matmul_STORAGE_GLOBAL %insert_BYTE-SIZE56, 0
  %c_offset_058 = load i64, ptr %c_offset_0, align 4
  %arr_ins_059 = insertvalue [2 x i64] undef, i64 %c_offset_058, 0
  %c_offset_160 = load i64, ptr %c_offset_1, align 4
  %arr_ins_161 = insertvalue [2 x i64] %arr_ins_059, i64 %c_offset_160, 1
  %insert_OFFSET62 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_PARENT57, [2 x i64] %arr_ins_161, 1
  %c_stride_063 = load i64, ptr %c_stride_0, align 4
  %arr_ins_064 = insertvalue [2 x i64] undef, i64 %c_stride_063, 0
  %c_stride_165 = load i64, ptr %c_stride_1, align 4
  %arr_ins_166 = insertvalue [2 x i64] %arr_ins_064, i64 %c_stride_165, 1
  %insert_STRIDES67 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_OFFSET62, [2 x i64] %arr_ins_166, 2
  %c_extent_068 = load i64, ptr %c_extent_0, align 4
  %arr_ins_069 = insertvalue [2 x i64] undef, i64 %c_extent_068, 0
  %c_extent_170 = load i64, ptr %c_extent_1, align 4
  %arr_ins_171 = insertvalue [2 x i64] %arr_ins_069, i64 %c_extent_170, 1
  %insert_EXTENTS72 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_STRIDES67, [2 x i64] %arr_ins_171, 3
  %c_length73 = load i64, ptr %c_length, align 4
  %insert_LENGTH74 = insertvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_EXTENTS72, i64 %c_length73, 4
  %c = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_LENGTH74, ptr %c, align 8
  %scratch_tensor_val = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %a-tile_from_tiled_matmul_1, align 8
  %a-tile = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %scratch_tensor_val, ptr %a-tile, align 8
  %scratch_tensor_val75 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %b-tile_from_tiled_matmul_2, align 8
  %b-tile = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %scratch_tensor_val75, ptr %b-tile, align 8
  %"c-tile$f0" = alloca %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8, align 8
  store %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 zeroinitializer, ptr %"c-tile$f0", align 4
  %arr_field_ptr = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr = getelementptr inbounds [2 x i64], ptr %arr_field_ptr, i32 0, i64 1
  %arr_elem = load i64, ptr %arr_elem_ptr, align 4
  %trunc_cast = trunc i64 %arr_elem to i32
  %k = alloca i32, align 4
  store i32 %trunc_cast, ptr %k, align 4
  %k76 = load i32, ptr %k, align 4
  %iop_tmp = sdiv i32 %k76, 8
  %kt = alloca i32, align 4
  store i32 0, ptr %kt, align 4
  br label %dt_check

dt_check:                                         ; preds = %dt_exit215, %entry
  %i = load i32, ptr %kt, align 4
  %dt_cond = icmp slt i32 %i, %iop_tmp
  br i1 %dt_cond, label %dt_body, label %dt_exit

dt_body:                                          ; preds = %dt_check
  %a77 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %src354 = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a77, ptr %src354, align 8
  %a-tile78 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %a-tile, align 8
  %tile355 = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %a-tile78, ptr %tile355, align 8
  %ident356 = alloca i32, align 4
  store i32 0, ptr %ident356, align 4
  %orig0357 = alloca i64, align 8
  store i64 0, ptr %orig0357, align 4
  %kt79 = load i32, ptr %kt, align 4
  %iop_tmp80 = mul i32 %kt79, 8
  %sext_cast = sext i32 %iop_tmp80 to i64
  %orig1358 = alloca i64, align 8
  store i64 %sext_cast, ptr %orig1358, align 4
  %arr_field_ptr81 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %tile355, i32 0, i32 3
  %arr_elem_ptr82 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr81, i32 0, i64 0
  %arr_elem83 = load i64, ptr %arr_elem_ptr82, align 4
  %te0361 = alloca i64, align 8
  store i64 %arr_elem83, ptr %te0361, align 4
  %arr_field_ptr84 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %tile355, i32 0, i32 3
  %arr_elem_ptr85 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr84, i32 0, i64 1
  %arr_elem86 = load i64, ptr %arr_elem_ptr85, align 4
  %te1362 = alloca i64, align 8
  store i64 %arr_elem86, ptr %te1362, align 4
  %arr_field_ptr87 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %src354, i32 0, i32 3
  %arr_elem_ptr88 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr87, i32 0, i64 0
  %arr_elem89 = load i64, ptr %arr_elem_ptr88, align 4
  %ge0363 = alloca i64, align 8
  store i64 %arr_elem89, ptr %ge0363, align 4
  %arr_field_ptr90 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %src354, i32 0, i32 3
  %arr_elem_ptr91 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr90, i32 0, i64 1
  %arr_elem92 = load i64, ptr %arr_elem_ptr91, align 4
  %ge1364 = alloca i64, align 8
  store i64 %arr_elem92, ptr %ge1364, align 4
  %localinvocationid = load <3 x i64>, ptr addrspace(1) @__spirv_BuiltInLocalInvocationId, align 32
  %localinvocationid_0 = extractelement <3 x i64> %localinvocationid, i32 0
  %lid0365 = alloca i64, align 8
  store i64 %localinvocationid_0, ptr %lid0365, align 4
  %localinvocationid93 = load <3 x i64>, ptr addrspace(1) @__spirv_BuiltInLocalInvocationId, align 32
  %localinvocationid_1 = extractelement <3 x i64> %localinvocationid93, i32 1
  %lid1366 = alloca i64, align 8
  store i64 %localinvocationid_1, ptr %lid1366, align 4
  %workgroupsize = load <3 x i64>, ptr addrspace(1) @__spirv_BuiltInWorkgroupSize, align 32
  %workgroupsize_0 = extractelement <3 x i64> %workgroupsize, i32 0
  %lws0367 = alloca i64, align 8
  store i64 %workgroupsize_0, ptr %lws0367, align 4
  %workgroupsize94 = load <3 x i64>, ptr addrspace(1) @__spirv_BuiltInWorkgroupSize, align 32
  %workgroupsize_1 = extractelement <3 x i64> %workgroupsize94, i32 1
  %lws1368 = alloca i64, align 8
  store i64 %workgroupsize_1, ptr %lws1368, align 4
  %te036195 = load i64, ptr %te0361, align 4
  %lws036796 = load i64, ptr %lws0367, align 4
  %k0369 = alloca i64, align 8
  store i64 0, ptr %k0369, align 4
  br label %dt_check97

dt_exit:                                          ; preds = %dt_check
  %"c-tile$f0450" = load %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %"c-tile$f0", align 4
  %frag-val = alloca %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8, align 8
  store %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f0450", ptr %frag-val, align 4
  %subgrouplocalinvocationid451 = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane452 = alloca i32, align 4
  store i32 %subgrouplocalinvocationid451, ptr %lane452, align 4
  %lane453 = load i32, ptr %lane452, align 4
  %iop_tmp454 = sdiv i32 %lane453, 4
  %g455 = alloca i32, align 4
  store i32 %iop_tmp454, ptr %g455, align 4
  %lane456 = load i32, ptr %lane452, align 4
  %mod-x392 = alloca i32, align 4
  store i32 %lane456, ptr %mod-x392, align 4
  %mod-y393 = alloca i32, align 4
  store i32 4, ptr %mod-y393, align 4
  %mod-x392457 = load i32, ptr %mod-x392, align 4
  %mod-x392458 = load i32, ptr %mod-x392, align 4
  %mod-y393459 = load i32, ptr %mod-y393, align 4
  %iop_tmp460 = sdiv i32 %mod-x392458, %mod-y393459
  %mod-y393461 = load i32, ptr %mod-y393, align 4
  %iop_tmp462 = mul i32 %iop_tmp460, %mod-y393461
  %iop_tmp463 = sub i32 %mod-x392457, %iop_tmp462
  %iop_tmp464 = mul i32 2, %iop_tmp463
  %t2 = alloca i32, align 4
  store i32 %iop_tmp464, ptr %t2, align 4
  %g465 = load i32, ptr %g455, align 4
  %iop_tmp466 = add i32 0, %g465
  %row = alloca i32, align 4
  store i32 %iop_tmp466, ptr %row, align 4
  %t2467 = load i32, ptr %t2, align 4
  %iop_tmp468 = add i32 0, %t2467
  %col = alloca i32, align 4
  store i32 %iop_tmp468, ptr %col, align 4
  %frag-val469 = load %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_0 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val469, 0
  %row470 = load i32, ptr %row, align 4
  %sext_cast471 = sext i32 %row470 to i64
  %arr_field_ptr472 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr473 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr472, i32 0, i64 1
  %arr_elem474 = load i64, ptr %arr_elem_ptr473, align 4
  %iop_tmp475 = mul i64 %sext_cast471, %arr_elem474
  %col476 = load i32, ptr %col, align 4
  %sext_cast477 = sext i32 %col476 to i64
  %iop_tmp478 = add i64 %iop_tmp475, %sext_cast477
  %c479 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val480 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c479, 0
  %t_base_ptr481 = extractvalue %S_06_tiled_matmul_STORAGE_GLOBAL %t_parent_val480, 0
  %t_byte_off482 = mul i64 %iop_tmp478, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8483 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr481, i64 %t_byte_off482
  %t_elem484 = load float, ptr addrspace(1) %t_ptr_i8483, align 4
  store float %extract_0, ptr addrspace(1) %t_ptr_i8483, align 4
  %frag-val485 = load %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_1 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val485, 1
  %row486 = load i32, ptr %row, align 4
  %sext_cast487 = sext i32 %row486 to i64
  %arr_field_ptr488 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr489 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr488, i32 0, i64 1
  %arr_elem490 = load i64, ptr %arr_elem_ptr489, align 4
  %iop_tmp491 = mul i64 %sext_cast487, %arr_elem490
  %col492 = load i32, ptr %col, align 4
  %iop_tmp493 = add i32 %col492, 1
  %sext_cast494 = sext i32 %iop_tmp493 to i64
  %iop_tmp495 = add i64 %iop_tmp491, %sext_cast494
  %c496 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val497 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c496, 0
  %t_base_ptr498 = extractvalue %S_06_tiled_matmul_STORAGE_GLOBAL %t_parent_val497, 0
  %t_byte_off499 = mul i64 %iop_tmp495, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8500 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr498, i64 %t_byte_off499
  %t_elem501 = load float, ptr addrspace(1) %t_ptr_i8500, align 4
  store float %extract_1, ptr addrspace(1) %t_ptr_i8500, align 4
  %frag-val502 = load %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_2 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val502, 2
  %row503 = load i32, ptr %row, align 4
  %iop_tmp504 = add i32 %row503, 8
  %sext_cast505 = sext i32 %iop_tmp504 to i64
  %arr_field_ptr506 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr507 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr506, i32 0, i64 1
  %arr_elem508 = load i64, ptr %arr_elem_ptr507, align 4
  %iop_tmp509 = mul i64 %sext_cast505, %arr_elem508
  %col510 = load i32, ptr %col, align 4
  %sext_cast511 = sext i32 %col510 to i64
  %iop_tmp512 = add i64 %iop_tmp509, %sext_cast511
  %c513 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val514 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c513, 0
  %t_base_ptr515 = extractvalue %S_06_tiled_matmul_STORAGE_GLOBAL %t_parent_val514, 0
  %t_byte_off516 = mul i64 %iop_tmp512, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8517 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr515, i64 %t_byte_off516
  %t_elem518 = load float, ptr addrspace(1) %t_ptr_i8517, align 4
  store float %extract_2, ptr addrspace(1) %t_ptr_i8517, align 4
  %frag-val519 = load %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_3 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val519, 3
  %row520 = load i32, ptr %row, align 4
  %iop_tmp521 = add i32 %row520, 8
  %sext_cast522 = sext i32 %iop_tmp521 to i64
  %arr_field_ptr523 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr524 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr523, i32 0, i64 1
  %arr_elem525 = load i64, ptr %arr_elem_ptr524, align 4
  %iop_tmp526 = mul i64 %sext_cast522, %arr_elem525
  %col527 = load i32, ptr %col, align 4
  %iop_tmp528 = add i32 %col527, 1
  %sext_cast529 = sext i32 %iop_tmp528 to i64
  %iop_tmp530 = add i64 %iop_tmp526, %sext_cast529
  %c531 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val532 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c531, 0
  %t_base_ptr533 = extractvalue %S_06_tiled_matmul_STORAGE_GLOBAL %t_parent_val532, 0
  %t_byte_off534 = mul i64 %iop_tmp530, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8535 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr533, i64 %t_byte_off534
  %t_elem536 = load float, ptr addrspace(1) %t_ptr_i8535, align 4
  store float %extract_3, ptr addrspace(1) %t_ptr_i8535, align 4
  ret void

dt_check97:                                       ; preds = %ifcont, %dt_body
  %i100 = load i64, ptr %k0369, align 4
  %dt_cond101 = icmp ult i64 %i100, %te036195
  br i1 %dt_cond101, label %dt_body98, label %dt_exit99

dt_body98:                                        ; preds = %dt_check97
  %k0369102 = load i64, ptr %k0369, align 4
  %lid0365103 = load i64, ptr %lid0365, align 4
  %iop_tmp104 = add i64 %k0369102, %lid0365103
  %tlc0359 = alloca i64, align 8
  store i64 %iop_tmp104, ptr %tlc0359, align 4
  %tlc0359105 = load i64, ptr %tlc0359, align 4
  %te0361106 = load i64, ptr %te0361, align 4
  %icmp_tmp = icmp ult i64 %tlc0359105, %te0361106
  %bool_ext = zext i1 %icmp_tmp to i32
  %ifcond = icmp ne i32 %bool_ext, 0
  br i1 %ifcond, label %then, label %else

dt_exit99:                                        ; preds = %dt_check97
  call void @__spirv_ControlBarrier(i32 2, i32 2, i32 264)
  %b186 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, align 8
  %src371 = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %b186, ptr %src371, align 8
  %b-tile187 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %b-tile, align 8
  %tile372 = alloca %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, align 8
  store %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %b-tile187, ptr %tile372, align 8
  %ident373 = alloca i32, align 4
  store i32 0, ptr %ident373, align 4
  %kt188 = load i32, ptr %kt, align 4
  %iop_tmp189 = mul i32 %kt188, 8
  %sext_cast190 = sext i32 %iop_tmp189 to i64
  %orig0374 = alloca i64, align 8
  store i64 %sext_cast190, ptr %orig0374, align 4
  %orig1375 = alloca i64, align 8
  store i64 0, ptr %orig1375, align 4
  %arr_field_ptr191 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %tile372, i32 0, i32 3
  %arr_elem_ptr192 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr191, i32 0, i64 0
  %arr_elem193 = load i64, ptr %arr_elem_ptr192, align 4
  %te0378 = alloca i64, align 8
  store i64 %arr_elem193, ptr %te0378, align 4
  %arr_field_ptr194 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %tile372, i32 0, i32 3
  %arr_elem_ptr195 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr194, i32 0, i64 1
  %arr_elem196 = load i64, ptr %arr_elem_ptr195, align 4
  %te1379 = alloca i64, align 8
  store i64 %arr_elem196, ptr %te1379, align 4
  %arr_field_ptr197 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %src371, i32 0, i32 3
  %arr_elem_ptr198 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr197, i32 0, i64 0
  %arr_elem199 = load i64, ptr %arr_elem_ptr198, align 4
  %ge0380 = alloca i64, align 8
  store i64 %arr_elem199, ptr %ge0380, align 4
  %arr_field_ptr200 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %src371, i32 0, i32 3
  %arr_elem_ptr201 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr200, i32 0, i64 1
  %arr_elem202 = load i64, ptr %arr_elem_ptr201, align 4
  %ge1381 = alloca i64, align 8
  store i64 %arr_elem202, ptr %ge1381, align 4
  %localinvocationid203 = load <3 x i64>, ptr addrspace(1) @__spirv_BuiltInLocalInvocationId, align 32
  %localinvocationid_0204 = extractelement <3 x i64> %localinvocationid203, i32 0
  %lid0382 = alloca i64, align 8
  store i64 %localinvocationid_0204, ptr %lid0382, align 4
  %localinvocationid205 = load <3 x i64>, ptr addrspace(1) @__spirv_BuiltInLocalInvocationId, align 32
  %localinvocationid_1206 = extractelement <3 x i64> %localinvocationid205, i32 1
  %lid1383 = alloca i64, align 8
  store i64 %localinvocationid_1206, ptr %lid1383, align 4
  %workgroupsize207 = load <3 x i64>, ptr addrspace(1) @__spirv_BuiltInWorkgroupSize, align 32
  %workgroupsize_0208 = extractelement <3 x i64> %workgroupsize207, i32 0
  %lws0384 = alloca i64, align 8
  store i64 %workgroupsize_0208, ptr %lws0384, align 4
  %workgroupsize209 = load <3 x i64>, ptr addrspace(1) @__spirv_BuiltInWorkgroupSize, align 32
  %workgroupsize_1210 = extractelement <3 x i64> %workgroupsize209, i32 1
  %lws1385 = alloca i64, align 8
  store i64 %workgroupsize_1210, ptr %lws1385, align 4
  %te0378211 = load i64, ptr %te0378, align 4
  %lws0384212 = load i64, ptr %lws0384, align 4
  %k0386 = alloca i64, align 8
  store i64 0, ptr %k0386, align 4
  br label %dt_check213

then:                                             ; preds = %dt_body98
  %te1362107 = load i64, ptr %te1362, align 4
  %lws1368108 = load i64, ptr %lws1368, align 4
  %k1370 = alloca i64, align 8
  store i64 0, ptr %k1370, align 4
  br label %dt_check109

else:                                             ; preds = %dt_body98
  br label %ifcont

ifcont:                                           ; preds = %else, %dt_exit111
  %i_cur184 = load i64, ptr %k0369, align 4
  %i_next185 = add i64 %i_cur184, %lws036796
  store i64 %i_next185, ptr %k0369, align 4
  br label %dt_check97

dt_check109:                                      ; preds = %ifcont124, %then
  %i112 = load i64, ptr %k1370, align 4
  %dt_cond113 = icmp ult i64 %i112, %te1362107
  br i1 %dt_cond113, label %dt_body110, label %dt_exit111

dt_body110:                                       ; preds = %dt_check109
  %k1370114 = load i64, ptr %k1370, align 4
  %lid1366115 = load i64, ptr %lid1366, align 4
  %iop_tmp116 = add i64 %k1370114, %lid1366115
  %tlc1360 = alloca i64, align 8
  store i64 %iop_tmp116, ptr %tlc1360, align 4
  %tlc1360117 = load i64, ptr %tlc1360, align 4
  %te1362118 = load i64, ptr %te1362, align 4
  %icmp_tmp119 = icmp ult i64 %tlc1360117, %te1362118
  %bool_ext120 = zext i1 %icmp_tmp119 to i32
  %ifcond121 = icmp ne i32 %bool_ext120, 0
  br i1 %ifcond121, label %then122, label %else123

dt_exit111:                                       ; preds = %dt_check109
  br label %ifcont

then122:                                          ; preds = %dt_body110
  %orig0357125 = load i64, ptr %orig0357, align 4
  %tlc0359126 = load i64, ptr %tlc0359, align 4
  %iop_tmp127 = add i64 %orig0357125, %tlc0359126
  %ge0363128 = load i64, ptr %ge0363, align 4
  %icmp_tmp129 = icmp ult i64 %iop_tmp127, %ge0363128
  %bool_ext130 = zext i1 %icmp_tmp129 to i32
  %ifcond131 = icmp ne i32 %bool_ext130, 0
  %if_result = alloca i32, align 4
  br i1 %ifcond131, label %then132, label %else133

else123:                                          ; preds = %dt_body110
  br label %ifcont124

ifcont124:                                        ; preds = %else123, %ifcont144
  %i_cur = load i64, ptr %k1370, align 4
  %i_next = add i64 %i_cur, %lws1368108
  store i64 %i_next, ptr %k1370, align 4
  br label %dt_check109

then132:                                          ; preds = %then122
  %orig1358135 = load i64, ptr %orig1358, align 4
  %tlc1360136 = load i64, ptr %tlc1360, align 4
  %iop_tmp137 = add i64 %orig1358135, %tlc1360136
  %ge1364138 = load i64, ptr %ge1364, align 4
  %icmp_tmp139 = icmp ult i64 %iop_tmp137, %ge1364138
  %bool_ext140 = zext i1 %icmp_tmp139 to i32
  store i32 %bool_ext140, ptr %if_result, align 4
  br label %ifcont134

else133:                                          ; preds = %then122
  br label %ifcont134

ifcont134:                                        ; preds = %else133, %then132
  %if_res = load i32, ptr %if_result, align 4
  %ifcond141 = icmp ne i32 %if_res, 0
  br i1 %ifcond141, label %then142, label %else143

then142:                                          ; preds = %ifcont134
  %orig0357145 = load i64, ptr %orig0357, align 4
  %tlc0359146 = load i64, ptr %tlc0359, align 4
  %iop_tmp147 = add i64 %orig0357145, %tlc0359146
  %arr_field_ptr148 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %src354, i32 0, i32 3
  %arr_elem_ptr149 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr148, i32 0, i64 1
  %arr_elem150 = load i64, ptr %arr_elem_ptr149, align 4
  %iop_tmp151 = mul i64 %iop_tmp147, %arr_elem150
  %orig1358152 = load i64, ptr %orig1358, align 4
  %tlc1360153 = load i64, ptr %tlc1360, align 4
  %iop_tmp154 = add i64 %orig1358152, %tlc1360153
  %iop_tmp155 = add i64 %iop_tmp151, %iop_tmp154
  %src354156 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %src354, align 8
  %t_parent_val = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %src354156, 0
  %t_base_ptr = extractvalue %S_06_tiled_matmul_STORAGE_GLOBAL %t_parent_val, 0
  %t_byte_off = mul i64 %iop_tmp155, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr, i64 %t_byte_off
  %t_elem = load float, ptr addrspace(1) %t_ptr_i8, align 4
  %tlc0359157 = load i64, ptr %tlc0359, align 4
  %arr_field_ptr158 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %tile355, i32 0, i32 3
  %arr_elem_ptr159 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr158, i32 0, i64 1
  %arr_elem160 = load i64, ptr %arr_elem_ptr159, align 4
  %iop_tmp161 = mul i64 %tlc0359157, %arr_elem160
  %tlc1360162 = load i64, ptr %tlc1360, align 4
  %iop_tmp163 = add i64 %iop_tmp161, %tlc1360162
  %tile355164 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %tile355, align 8
  %t_parent_val165 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %tile355164, 0
  %t_base_ptr166 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %t_parent_val165, 0
  %t_byte_off167 = mul i64 %iop_tmp163, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8168 = getelementptr inbounds i8, ptr addrspace(3) %t_base_ptr166, i64 %t_byte_off167
  %t_elem169 = load float, ptr addrspace(3) %t_ptr_i8168, align 4
  store float %t_elem, ptr addrspace(3) %t_ptr_i8168, align 4
  br label %ifcont144

else143:                                          ; preds = %ifcont134
  %ident356170 = load i32, ptr %ident356, align 4
  %tlc0359171 = load i64, ptr %tlc0359, align 4
  %arr_field_ptr172 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %tile355, i32 0, i32 3
  %arr_elem_ptr173 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr172, i32 0, i64 1
  %arr_elem174 = load i64, ptr %arr_elem_ptr173, align 4
  %iop_tmp175 = mul i64 %tlc0359171, %arr_elem174
  %tlc1360176 = load i64, ptr %tlc1360, align 4
  %iop_tmp177 = add i64 %iop_tmp175, %tlc1360176
  %tile355178 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %tile355, align 8
  %t_parent_val179 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %tile355178, 0
  %t_base_ptr180 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %t_parent_val179, 0
  %t_byte_off181 = mul i64 %iop_tmp177, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8182 = getelementptr inbounds i8, ptr addrspace(3) %t_base_ptr180, i64 %t_byte_off181
  %t_elem183 = load float, ptr addrspace(3) %t_ptr_i8182, align 4
  store i32 %ident356170, ptr addrspace(3) %t_ptr_i8182, align 4
  br label %ifcont144

ifcont144:                                        ; preds = %else143, %then142
  br label %ifcont124

dt_check213:                                      ; preds = %ifcont228, %dt_exit99
  %i216 = load i64, ptr %k0386, align 4
  %dt_cond217 = icmp ult i64 %i216, %te0378211
  br i1 %dt_cond217, label %dt_body214, label %dt_exit215

dt_body214:                                       ; preds = %dt_check213
  %k0386218 = load i64, ptr %k0386, align 4
  %lid0382219 = load i64, ptr %lid0382, align 4
  %iop_tmp220 = add i64 %k0386218, %lid0382219
  %tlc0376 = alloca i64, align 8
  store i64 %iop_tmp220, ptr %tlc0376, align 4
  %tlc0376221 = load i64, ptr %tlc0376, align 4
  %te0378222 = load i64, ptr %te0378, align 4
  %icmp_tmp223 = icmp ult i64 %tlc0376221, %te0378222
  %bool_ext224 = zext i1 %icmp_tmp223 to i32
  %ifcond225 = icmp ne i32 %bool_ext224, 0
  br i1 %ifcond225, label %then226, label %else227

dt_exit215:                                       ; preds = %dt_check213
  call void @__spirv_ControlBarrier(i32 2, i32 2, i32 264)
  call void @__spirv_ControlBarrier(i32 2, i32 2, i32 264)
  %"c-tile$f0317" = load %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %"c-tile$f0", align 4
  %subgrouplocalinvocationid = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane = alloca i32, align 4
  store i32 %subgrouplocalinvocationid, ptr %lane, align 4
  %lane318 = load i32, ptr %lane, align 4
  %iop_tmp319 = sdiv i32 %lane318, 4
  %g = alloca i32, align 4
  store i32 %iop_tmp319, ptr %g, align 4
  %lane320 = load i32, ptr %lane, align 4
  %mod-x388 = alloca i32, align 4
  store i32 %lane320, ptr %mod-x388, align 4
  %mod-y389 = alloca i32, align 4
  store i32 4, ptr %mod-y389, align 4
  %mod-x388321 = load i32, ptr %mod-x388, align 4
  %mod-x388322 = load i32, ptr %mod-x388, align 4
  %mod-y389323 = load i32, ptr %mod-y389, align 4
  %iop_tmp324 = sdiv i32 %mod-x388322, %mod-y389323
  %mod-y389325 = load i32, ptr %mod-y389, align 4
  %iop_tmp326 = mul i32 %iop_tmp324, %mod-y389325
  %iop_tmp327 = sub i32 %mod-x388321, %iop_tmp326
  %tg = alloca i32, align 4
  store i32 %iop_tmp327, ptr %tg, align 4
  %g328 = load i32, ptr %g, align 4
  %iop_tmp329 = add i32 0, %g328
  %r = alloca i32, align 4
  store i32 %iop_tmp329, ptr %r, align 4
  %tg330 = load i32, ptr %tg, align 4
  %iop_tmp331 = add i32 0, %tg330
  %c332 = alloca i32, align 4
  store i32 %iop_tmp331, ptr %c332, align 4
  %r333 = load i32, ptr %r, align 4
  %sext_cast334 = sext i32 %r333 to i64
  %arr_field_ptr335 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %a-tile, i32 0, i32 3
  %arr_elem_ptr336 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr335, i32 0, i64 1
  %arr_elem337 = load i64, ptr %arr_elem_ptr336, align 4
  %iop_tmp338 = mul i64 %sext_cast334, %arr_elem337
  %c339 = load i32, ptr %c332, align 4
  %sext_cast340 = sext i32 %c339 to i64
  %iop_tmp341 = add i64 %iop_tmp338, %sext_cast340
  %a-tile342 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %a-tile, align 8
  %t_parent_val343 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %a-tile342, 0
  %t_base_ptr344 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %t_parent_val343, 0
  %t_byte_off345 = mul i64 %iop_tmp341, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8346 = getelementptr inbounds i8, ptr addrspace(3) %t_base_ptr344, i64 %t_byte_off345
  %t_elem347 = load float, ptr addrspace(3) %t_ptr_i8346, align 4
  %insert_A0 = insertvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-A-TF32-16X8 undef, float %t_elem347, 0
  %r348 = load i32, ptr %r, align 4
  %iop_tmp349 = add i32 %r348, 8
  %sext_cast350 = sext i32 %iop_tmp349 to i64
  %arr_field_ptr351 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %a-tile, i32 0, i32 3
  %arr_elem_ptr352 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr351, i32 0, i64 1
  %arr_elem353 = load i64, ptr %arr_elem_ptr352, align 4
  %iop_tmp354 = mul i64 %sext_cast350, %arr_elem353
  %c355 = load i32, ptr %c332, align 4
  %sext_cast356 = sext i32 %c355 to i64
  %iop_tmp357 = add i64 %iop_tmp354, %sext_cast356
  %a-tile358 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %a-tile, align 8
  %t_parent_val359 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %a-tile358, 0
  %t_base_ptr360 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %t_parent_val359, 0
  %t_byte_off361 = mul i64 %iop_tmp357, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8362 = getelementptr inbounds i8, ptr addrspace(3) %t_base_ptr360, i64 %t_byte_off361
  %t_elem363 = load float, ptr addrspace(3) %t_ptr_i8362, align 4
  %insert_A1 = insertvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A0, float %t_elem363, 1
  %r364 = load i32, ptr %r, align 4
  %sext_cast365 = sext i32 %r364 to i64
  %arr_field_ptr366 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %a-tile, i32 0, i32 3
  %arr_elem_ptr367 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr366, i32 0, i64 1
  %arr_elem368 = load i64, ptr %arr_elem_ptr367, align 4
  %iop_tmp369 = mul i64 %sext_cast365, %arr_elem368
  %c370 = load i32, ptr %c332, align 4
  %iop_tmp371 = add i32 %c370, 4
  %sext_cast372 = sext i32 %iop_tmp371 to i64
  %iop_tmp373 = add i64 %iop_tmp369, %sext_cast372
  %a-tile374 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %a-tile, align 8
  %t_parent_val375 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %a-tile374, 0
  %t_base_ptr376 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %t_parent_val375, 0
  %t_byte_off377 = mul i64 %iop_tmp373, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8378 = getelementptr inbounds i8, ptr addrspace(3) %t_base_ptr376, i64 %t_byte_off377
  %t_elem379 = load float, ptr addrspace(3) %t_ptr_i8378, align 4
  %insert_A2 = insertvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A1, float %t_elem379, 2
  %r380 = load i32, ptr %r, align 4
  %iop_tmp381 = add i32 %r380, 8
  %sext_cast382 = sext i32 %iop_tmp381 to i64
  %arr_field_ptr383 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %a-tile, i32 0, i32 3
  %arr_elem_ptr384 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr383, i32 0, i64 1
  %arr_elem385 = load i64, ptr %arr_elem_ptr384, align 4
  %iop_tmp386 = mul i64 %sext_cast382, %arr_elem385
  %c387 = load i32, ptr %c332, align 4
  %iop_tmp388 = add i32 %c387, 4
  %sext_cast389 = sext i32 %iop_tmp388 to i64
  %iop_tmp390 = add i64 %iop_tmp386, %sext_cast389
  %a-tile391 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %a-tile, align 8
  %t_parent_val392 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %a-tile391, 0
  %t_base_ptr393 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %t_parent_val392, 0
  %t_byte_off394 = mul i64 %iop_tmp390, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8395 = getelementptr inbounds i8, ptr addrspace(3) %t_base_ptr393, i64 %t_byte_off394
  %t_elem396 = load float, ptr addrspace(3) %t_ptr_i8395, align 4
  %insert_A3 = insertvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A2, float %t_elem396, 3
  %subgrouplocalinvocationid397 = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane398 = alloca i32, align 4
  store i32 %subgrouplocalinvocationid397, ptr %lane398, align 4
  %lane399 = load i32, ptr %lane398, align 4
  %iop_tmp400 = sdiv i32 %lane399, 4
  %g401 = alloca i32, align 4
  store i32 %iop_tmp400, ptr %g401, align 4
  %lane402 = load i32, ptr %lane398, align 4
  %mod-x390 = alloca i32, align 4
  store i32 %lane402, ptr %mod-x390, align 4
  %mod-y391 = alloca i32, align 4
  store i32 4, ptr %mod-y391, align 4
  %mod-x390403 = load i32, ptr %mod-x390, align 4
  %mod-x390404 = load i32, ptr %mod-x390, align 4
  %mod-y391405 = load i32, ptr %mod-y391, align 4
  %iop_tmp406 = sdiv i32 %mod-x390404, %mod-y391405
  %mod-y391407 = load i32, ptr %mod-y391, align 4
  %iop_tmp408 = mul i32 %iop_tmp406, %mod-y391407
  %iop_tmp409 = sub i32 %mod-x390403, %iop_tmp408
  %tg410 = alloca i32, align 4
  store i32 %iop_tmp409, ptr %tg410, align 4
  %tg411 = load i32, ptr %tg410, align 4
  %iop_tmp412 = add i32 0, %tg411
  %r413 = alloca i32, align 4
  store i32 %iop_tmp412, ptr %r413, align 4
  %g414 = load i32, ptr %g401, align 4
  %iop_tmp415 = add i32 0, %g414
  %c416 = alloca i32, align 4
  store i32 %iop_tmp415, ptr %c416, align 4
  %r417 = load i32, ptr %r413, align 4
  %sext_cast418 = sext i32 %r417 to i64
  %arr_field_ptr419 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %b-tile, i32 0, i32 3
  %arr_elem_ptr420 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr419, i32 0, i64 1
  %arr_elem421 = load i64, ptr %arr_elem_ptr420, align 4
  %iop_tmp422 = mul i64 %sext_cast418, %arr_elem421
  %c423 = load i32, ptr %c416, align 4
  %sext_cast424 = sext i32 %c423 to i64
  %iop_tmp425 = add i64 %iop_tmp422, %sext_cast424
  %b-tile426 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %b-tile, align 8
  %t_parent_val427 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %b-tile426, 0
  %t_base_ptr428 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %t_parent_val427, 0
  %t_byte_off429 = mul i64 %iop_tmp425, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8430 = getelementptr inbounds i8, ptr addrspace(3) %t_base_ptr428, i64 %t_byte_off429
  %t_elem431 = load float, ptr addrspace(3) %t_ptr_i8430, align 4
  %insert_B0 = insertvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-B-TF32-8X8 undef, float %t_elem431, 0
  %r432 = load i32, ptr %r413, align 4
  %iop_tmp433 = add i32 %r432, 4
  %sext_cast434 = sext i32 %iop_tmp433 to i64
  %arr_field_ptr435 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %b-tile, i32 0, i32 3
  %arr_elem_ptr436 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr435, i32 0, i64 1
  %arr_elem437 = load i64, ptr %arr_elem_ptr436, align 4
  %iop_tmp438 = mul i64 %sext_cast434, %arr_elem437
  %c439 = load i32, ptr %c416, align 4
  %sext_cast440 = sext i32 %c439 to i64
  %iop_tmp441 = add i64 %iop_tmp438, %sext_cast440
  %b-tile442 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %b-tile, align 8
  %t_parent_val443 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %b-tile442, 0
  %t_base_ptr444 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %t_parent_val443, 0
  %t_byte_off445 = mul i64 %iop_tmp441, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8446 = getelementptr inbounds i8, ptr addrspace(3) %t_base_ptr444, i64 %t_byte_off445
  %t_elem447 = load float, ptr addrspace(3) %t_ptr_i8446, align 4
  %insert_B1 = insertvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B0, float %t_elem447, 1
  %a0 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, 0
  %a0i = bitcast float %a0 to i32
  %a1 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, 1
  %a1i = bitcast float %a1 to i32
  %a2 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, 2
  %a2i = bitcast float %a2 to i32
  %a3 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, 3
  %a3i = bitcast float %a3 to i32
  %b0 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B1, 0
  %b0i = bitcast float %b0 to i32
  %b1 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B1, 1
  %b1i = bitcast float %b1 to i32
  %c0 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f0317", 0
  %c1 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f0317", 1
  %c2 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f0317", 2
  %c3 = extractvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f0317", 3
  %mma = call { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32 %a0i, i32 %a1i, i32 %a2i, i32 %a3i, i32 %b0i, i32 %b1i, float %c0, float %c1, float %c2, float %c3)
  %d0 = extractvalue { float, float, float, float } %mma, 0
  %acc0 = insertvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 undef, float %d0, 0
  %d1 = extractvalue { float, float, float, float } %mma, 1
  %acc1 = insertvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %acc0, float %d1, 1
  %d2 = extractvalue { float, float, float, float } %mma, 2
  %acc2 = insertvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %acc1, float %d2, 2
  %d3 = extractvalue { float, float, float, float } %mma, 3
  %acc3 = insertvalue %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %acc2, float %d3, 3
  store %S_06_tiled_matmul_REGISTER-FRAGMENT-ACC-F32-16X8 %acc3, ptr %"c-tile$f0", align 4
  call void @__spirv_ControlBarrier(i32 2, i32 2, i32 264)
  %i_cur448 = load i32, ptr %kt, align 4
  %i_next449 = add i32 %i_cur448, 1
  store i32 %i_next449, ptr %kt, align 4
  br label %dt_check

then226:                                          ; preds = %dt_body214
  %te1379229 = load i64, ptr %te1379, align 4
  %lws1385230 = load i64, ptr %lws1385, align 4
  %k1387 = alloca i64, align 8
  store i64 0, ptr %k1387, align 4
  br label %dt_check231

else227:                                          ; preds = %dt_body214
  br label %ifcont228

ifcont228:                                        ; preds = %else227, %dt_exit233
  %i_cur315 = load i64, ptr %k0386, align 4
  %i_next316 = add i64 %i_cur315, %lws0384212
  store i64 %i_next316, ptr %k0386, align 4
  br label %dt_check213

dt_check231:                                      ; preds = %ifcont246, %then226
  %i234 = load i64, ptr %k1387, align 4
  %dt_cond235 = icmp ult i64 %i234, %te1379229
  br i1 %dt_cond235, label %dt_body232, label %dt_exit233

dt_body232:                                       ; preds = %dt_check231
  %k1387236 = load i64, ptr %k1387, align 4
  %lid1383237 = load i64, ptr %lid1383, align 4
  %iop_tmp238 = add i64 %k1387236, %lid1383237
  %tlc1377 = alloca i64, align 8
  store i64 %iop_tmp238, ptr %tlc1377, align 4
  %tlc1377239 = load i64, ptr %tlc1377, align 4
  %te1379240 = load i64, ptr %te1379, align 4
  %icmp_tmp241 = icmp ult i64 %tlc1377239, %te1379240
  %bool_ext242 = zext i1 %icmp_tmp241 to i32
  %ifcond243 = icmp ne i32 %bool_ext242, 0
  br i1 %ifcond243, label %then244, label %else245

dt_exit233:                                       ; preds = %dt_check231
  br label %ifcont228

then244:                                          ; preds = %dt_body232
  %orig0374247 = load i64, ptr %orig0374, align 4
  %tlc0376248 = load i64, ptr %tlc0376, align 4
  %iop_tmp249 = add i64 %orig0374247, %tlc0376248
  %ge0380250 = load i64, ptr %ge0380, align 4
  %icmp_tmp251 = icmp ult i64 %iop_tmp249, %ge0380250
  %bool_ext252 = zext i1 %icmp_tmp251 to i32
  %ifcond253 = icmp ne i32 %bool_ext252, 0
  %if_result257 = alloca i32, align 4
  br i1 %ifcond253, label %then254, label %else255

else245:                                          ; preds = %dt_body232
  br label %ifcont246

ifcont246:                                        ; preds = %else245, %ifcont268
  %i_cur313 = load i64, ptr %k1387, align 4
  %i_next314 = add i64 %i_cur313, %lws1385230
  store i64 %i_next314, ptr %k1387, align 4
  br label %dt_check231

then254:                                          ; preds = %then244
  %orig1375258 = load i64, ptr %orig1375, align 4
  %tlc1377259 = load i64, ptr %tlc1377, align 4
  %iop_tmp260 = add i64 %orig1375258, %tlc1377259
  %ge1381261 = load i64, ptr %ge1381, align 4
  %icmp_tmp262 = icmp ult i64 %iop_tmp260, %ge1381261
  %bool_ext263 = zext i1 %icmp_tmp262 to i32
  store i32 %bool_ext263, ptr %if_result257, align 4
  br label %ifcont256

else255:                                          ; preds = %then244
  br label %ifcont256

ifcont256:                                        ; preds = %else255, %then254
  %if_res264 = load i32, ptr %if_result257, align 4
  %ifcond265 = icmp ne i32 %if_res264, 0
  br i1 %ifcond265, label %then266, label %else267

then266:                                          ; preds = %ifcont256
  %orig0374269 = load i64, ptr %orig0374, align 4
  %tlc0376270 = load i64, ptr %tlc0376, align 4
  %iop_tmp271 = add i64 %orig0374269, %tlc0376270
  %arr_field_ptr272 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %src371, i32 0, i32 3
  %arr_elem_ptr273 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr272, i32 0, i64 1
  %arr_elem274 = load i64, ptr %arr_elem_ptr273, align 4
  %iop_tmp275 = mul i64 %iop_tmp271, %arr_elem274
  %orig1375276 = load i64, ptr %orig1375, align 4
  %tlc1377277 = load i64, ptr %tlc1377, align 4
  %iop_tmp278 = add i64 %orig1375276, %tlc1377277
  %iop_tmp279 = add i64 %iop_tmp275, %iop_tmp278
  %src371280 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %src371, align 8
  %t_parent_val281 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %src371280, 0
  %t_base_ptr282 = extractvalue %S_06_tiled_matmul_STORAGE_GLOBAL %t_parent_val281, 0
  %t_byte_off283 = mul i64 %iop_tmp279, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8284 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr282, i64 %t_byte_off283
  %t_elem285 = load float, ptr addrspace(1) %t_ptr_i8284, align 4
  %tlc0376286 = load i64, ptr %tlc0376, align 4
  %arr_field_ptr287 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %tile372, i32 0, i32 3
  %arr_elem_ptr288 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr287, i32 0, i64 1
  %arr_elem289 = load i64, ptr %arr_elem_ptr288, align 4
  %iop_tmp290 = mul i64 %tlc0376286, %arr_elem289
  %tlc1377291 = load i64, ptr %tlc1377, align 4
  %iop_tmp292 = add i64 %iop_tmp290, %tlc1377291
  %tile372293 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %tile372, align 8
  %t_parent_val294 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %tile372293, 0
  %t_base_ptr295 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %t_parent_val294, 0
  %t_byte_off296 = mul i64 %iop_tmp292, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8297 = getelementptr inbounds i8, ptr addrspace(3) %t_base_ptr295, i64 %t_byte_off296
  %t_elem298 = load float, ptr addrspace(3) %t_ptr_i8297, align 4
  store float %t_elem285, ptr addrspace(3) %t_ptr_i8297, align 4
  br label %ifcont268

else267:                                          ; preds = %ifcont256
  %ident373299 = load i32, ptr %ident373, align 4
  %tlc0376300 = load i64, ptr %tlc0376, align 4
  %arr_field_ptr301 = getelementptr inbounds %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %tile372, i32 0, i32 3
  %arr_elem_ptr302 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr301, i32 0, i64 1
  %arr_elem303 = load i64, ptr %arr_elem_ptr302, align 4
  %iop_tmp304 = mul i64 %tlc0376300, %arr_elem303
  %tlc1377305 = load i64, ptr %tlc1377, align 4
  %iop_tmp306 = add i64 %iop_tmp304, %tlc1377305
  %tile372307 = load %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST, ptr %tile372, align 8
  %t_parent_val308 = extractvalue %S_06_tiled_matmul_TENSOR_FLOAT_2_LOCAL_COMPACT_LAST %tile372307, 0
  %t_base_ptr309 = extractvalue %S_06_tiled_matmul_STORAGE_LOCAL %t_parent_val308, 0
  %t_byte_off310 = mul i64 %iop_tmp306, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8311 = getelementptr inbounds i8, ptr addrspace(3) %t_base_ptr309, i64 %t_byte_off310
  %t_elem312 = load float, ptr addrspace(3) %t_ptr_i8311, align 4
  store i32 %ident373299, ptr addrspace(3) %t_ptr_i8311, align 4
  br label %ifcont268

ifcont268:                                        ; preds = %else267, %then266
  br label %ifcont246
}

declare void @__spirv_ControlBarrier(i32, i32, i32)

; Function Attrs: nocallback nounwind memory(none)
declare { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32, i32, i32, i32, i32, i32, float, float, float, float) #1

attributes #0 = { "denormal-fp-math"="ieee,ieee" "denormal-fp-math-f32"="ieee,ieee" }
attributes #1 = { nocallback nounwind memory(none) }

!spirv.ExecutionMode = !{!0}

!0 = !{ptr @tiled_matmul, i32 4459, i32 32}


!100 = !{i32 3, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 3, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0}
!101 = !{!"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none"}
!102 = !{!"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong"}
!103 = !{!"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong"}
!104 = !{!"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !""}
