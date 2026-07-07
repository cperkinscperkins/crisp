; ModuleID = '05-mma-via-tile-multi'
source_filename = "05-mma-via-tile-multi"
target triple = "spir64-unknown-unknown"

%S_05_mma_via_tile_multi_STORAGE_GLOBAL = type { ptr addrspace(1), i64 }
%S_05_mma_via_tile_multi_CELL_INT_GLOBAL = type { %S_05_mma_via_tile_multi_STORAGE_GLOBAL, i64 }
%S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST = type { %S_05_mma_via_tile_multi_STORAGE_GLOBAL, [2 x i64], [2 x i64], [2 x i64], i64 }
%S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST = type { %S_05_mma_via_tile_multi_STORAGE_GLOBAL, [2 x i64], [2 x i64], [2 x i64], i64 }
%S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 = type { float, float, float, float }
%S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 = type { float, float, float, float }
%S_05_mma_via_tile_multi_REGISTER-FRAGMENT-B-TF32-8X8 = type { float, float }

@__spirv_BuiltInSubgroupLocalInvocationId = addrspace(1) global i32 0

define spir_func ptr addrspace(1) @address__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_05_mma_via_tile_multi_STORAGE_GLOBAL, align 8
  store %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_05_mma_via_tile_multi_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %obj1, 0
  ret ptr addrspace(1) %extract_0
}

define spir_func i64 @byte_size__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_05_mma_via_tile_multi_STORAGE_GLOBAL, align 8
  store %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_05_mma_via_tile_multi_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func i32 @address_space__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_05_mma_via_tile_multi_STORAGE_GLOBAL, align 8
  store %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func ptr addrspace(1) @_address__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_05_mma_via_tile_multi_STORAGE_GLOBAL, align 8
  store %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_05_mma_via_tile_multi_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %obj1, 0
  ret ptr addrspace(1) %extract_0
}

define spir_func i64 @_byte_size__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_05_mma_via_tile_multi_STORAGE_GLOBAL, align 8
  store %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_05_mma_via_tile_multi_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func %S_05_mma_via_tile_multi_STORAGE_GLOBAL @parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_05_mma_via_tile_multi_CELL_INT_GLOBAL, align 8
  store %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_05_mma_via_tile_multi_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %obj1, 0
  ret %S_05_mma_via_tile_multi_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @offset__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_05_mma_via_tile_multi_CELL_INT_GLOBAL, align 8
  store %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_05_mma_via_tile_multi_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func i32 @address_space__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_05_mma_via_tile_multi_CELL_INT_GLOBAL, align 8
  store %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func %S_05_mma_via_tile_multi_STORAGE_GLOBAL @_parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_05_mma_via_tile_multi_CELL_INT_GLOBAL, align 8
  store %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_05_mma_via_tile_multi_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %obj1, 0
  ret %S_05_mma_via_tile_multi_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @_offset__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_05_mma_via_tile_multi_CELL_INT_GLOBAL, align 8
  store %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_05_mma_via_tile_multi_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_05_mma_via_tile_multi_CELL_INT_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func %S_05_mma_via_tile_multi_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 0
  ret %S_05_mma_via_tile_multi_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @length__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 4
  ret i64 %extract_4
}

define spir_func i64 @num_dims__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i64 2
}

define spir_func i32 @address_space__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func i32 @align__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func i32 @contiguous_term__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func %S_05_mma_via_tile_multi_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 0
  ret %S_05_mma_via_tile_multi_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @_length__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 4
  ret i64 %extract_4
}

define spir_func %S_05_mma_via_tile_multi_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_0 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 0
  ret %S_05_mma_via_tile_multi_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @length__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_4 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 4
  ret i64 %extract_4
}

define spir_func i64 @num_dims__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i64 2
}

define spir_func i32 @address_space__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func i32 @align__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func i32 @contiguous_term__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func %S_05_mma_via_tile_multi_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_0 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 0
  ret %S_05_mma_via_tile_multi_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @_length__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_4 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 4
  ret i64 %extract_4
}

define spir_kernel void @via_tile_multi(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8, ptr addrspace(1) %9, i64 %10, i64 %11, i64 %12, i64 %13, i64 %14, i64 %15, i64 %16, i64 %17, ptr addrspace(1) %18, i64 %19, i64 %20, i64 %21, i64 %22, i64 %23, i64 %24, i64 %25, i64 %26) !kernel_arg_addr_space !100 !kernel_arg_access_qual !101 !kernel_arg_type !102 !kernel_arg_base_type !103 !kernel_arg_type_qual !104 {
entry:
  %a_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %0, ptr %a_ptr, align 8
  %a_byte_size = alloca i64, align 8
  store i64 %1, ptr %a_byte_size, align 4
  %a_offset_0 = alloca i64, align 8
  store i64 %2, ptr %a_offset_0, align 4
  %a_offset_1 = alloca i64, align 8
  store i64 %3, ptr %a_offset_1, align 4
  %a_stride_0 = alloca i64, align 8
  store i64 %4, ptr %a_stride_0, align 4
  %a_stride_1 = alloca i64, align 8
  store i64 %5, ptr %a_stride_1, align 4
  %a_extent_0 = alloca i64, align 8
  store i64 %6, ptr %a_extent_0, align 4
  %a_extent_1 = alloca i64, align 8
  store i64 %7, ptr %a_extent_1, align 4
  %a_length = alloca i64, align 8
  store i64 %8, ptr %a_length, align 4
  %b_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %9, ptr %b_ptr, align 8
  %b_byte_size = alloca i64, align 8
  store i64 %10, ptr %b_byte_size, align 4
  %b_offset_0 = alloca i64, align 8
  store i64 %11, ptr %b_offset_0, align 4
  %b_offset_1 = alloca i64, align 8
  store i64 %12, ptr %b_offset_1, align 4
  %b_stride_0 = alloca i64, align 8
  store i64 %13, ptr %b_stride_0, align 4
  %b_stride_1 = alloca i64, align 8
  store i64 %14, ptr %b_stride_1, align 4
  %b_extent_0 = alloca i64, align 8
  store i64 %15, ptr %b_extent_0, align 4
  %b_extent_1 = alloca i64, align 8
  store i64 %16, ptr %b_extent_1, align 4
  %b_length = alloca i64, align 8
  store i64 %17, ptr %b_length, align 4
  %c_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %18, ptr %c_ptr, align 8
  %c_byte_size = alloca i64, align 8
  store i64 %19, ptr %c_byte_size, align 4
  %c_offset_0 = alloca i64, align 8
  store i64 %20, ptr %c_offset_0, align 4
  %c_offset_1 = alloca i64, align 8
  store i64 %21, ptr %c_offset_1, align 4
  %c_stride_0 = alloca i64, align 8
  store i64 %22, ptr %c_stride_0, align 4
  %c_stride_1 = alloca i64, align 8
  store i64 %23, ptr %c_stride_1, align 4
  %c_extent_0 = alloca i64, align 8
  store i64 %24, ptr %c_extent_0, align 4
  %c_extent_1 = alloca i64, align 8
  store i64 %25, ptr %c_extent_1, align 4
  %c_length = alloca i64, align 8
  store i64 %26, ptr %c_length, align 4
  %a_ptr1 = load ptr addrspace(1), ptr %a_ptr, align 8
  %insert_ADDRESS = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %a_ptr1, 0
  %a_byte_size2 = load i64, ptr %a_byte_size, align 4
  %insert_BYTE-SIZE = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %insert_ADDRESS, i64 %a_byte_size2, 1
  %insert_PARENT = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %insert_BYTE-SIZE, 0
  %a_offset_03 = load i64, ptr %a_offset_0, align 4
  %arr_ins_0 = insertvalue [2 x i64] undef, i64 %a_offset_03, 0
  %a_offset_14 = load i64, ptr %a_offset_1, align 4
  %arr_ins_1 = insertvalue [2 x i64] %arr_ins_0, i64 %a_offset_14, 1
  %insert_OFFSET = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_PARENT, [2 x i64] %arr_ins_1, 1
  %a_stride_05 = load i64, ptr %a_stride_0, align 4
  %arr_ins_06 = insertvalue [2 x i64] undef, i64 %a_stride_05, 0
  %a_stride_17 = load i64, ptr %a_stride_1, align 4
  %arr_ins_18 = insertvalue [2 x i64] %arr_ins_06, i64 %a_stride_17, 1
  %insert_STRIDES = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_OFFSET, [2 x i64] %arr_ins_18, 2
  %a_extent_09 = load i64, ptr %a_extent_0, align 4
  %arr_ins_010 = insertvalue [2 x i64] undef, i64 %a_extent_09, 0
  %a_extent_111 = load i64, ptr %a_extent_1, align 4
  %arr_ins_112 = insertvalue [2 x i64] %arr_ins_010, i64 %a_extent_111, 1
  %insert_EXTENTS = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_STRIDES, [2 x i64] %arr_ins_112, 3
  %a_length13 = load i64, ptr %a_length, align 4
  %insert_LENGTH = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_EXTENTS, i64 %a_length13, 4
  %a = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_LENGTH, ptr %a, align 8
  %b_ptr14 = load ptr addrspace(1), ptr %b_ptr, align 8
  %insert_ADDRESS15 = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %b_ptr14, 0
  %b_byte_size16 = load i64, ptr %b_byte_size, align 4
  %insert_BYTE-SIZE17 = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %insert_ADDRESS15, i64 %b_byte_size16, 1
  %insert_PARENT18 = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %insert_BYTE-SIZE17, 0
  %b_offset_019 = load i64, ptr %b_offset_0, align 4
  %arr_ins_020 = insertvalue [2 x i64] undef, i64 %b_offset_019, 0
  %b_offset_121 = load i64, ptr %b_offset_1, align 4
  %arr_ins_122 = insertvalue [2 x i64] %arr_ins_020, i64 %b_offset_121, 1
  %insert_OFFSET23 = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_PARENT18, [2 x i64] %arr_ins_122, 1
  %b_stride_024 = load i64, ptr %b_stride_0, align 4
  %arr_ins_025 = insertvalue [2 x i64] undef, i64 %b_stride_024, 0
  %b_stride_126 = load i64, ptr %b_stride_1, align 4
  %arr_ins_127 = insertvalue [2 x i64] %arr_ins_025, i64 %b_stride_126, 1
  %insert_STRIDES28 = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_OFFSET23, [2 x i64] %arr_ins_127, 2
  %b_extent_029 = load i64, ptr %b_extent_0, align 4
  %arr_ins_030 = insertvalue [2 x i64] undef, i64 %b_extent_029, 0
  %b_extent_131 = load i64, ptr %b_extent_1, align 4
  %arr_ins_132 = insertvalue [2 x i64] %arr_ins_030, i64 %b_extent_131, 1
  %insert_EXTENTS33 = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_STRIDES28, [2 x i64] %arr_ins_132, 3
  %b_length34 = load i64, ptr %b_length, align 4
  %insert_LENGTH35 = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_EXTENTS33, i64 %b_length34, 4
  %b = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_LENGTH35, ptr %b, align 8
  %c_ptr36 = load ptr addrspace(1), ptr %c_ptr, align 8
  %insert_ADDRESS37 = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL undef, ptr addrspace(1) %c_ptr36, 0
  %c_byte_size38 = load i64, ptr %c_byte_size, align 4
  %insert_BYTE-SIZE39 = insertvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %insert_ADDRESS37, i64 %c_byte_size38, 1
  %insert_PARENT40 = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_05_mma_via_tile_multi_STORAGE_GLOBAL %insert_BYTE-SIZE39, 0
  %c_offset_041 = load i64, ptr %c_offset_0, align 4
  %arr_ins_042 = insertvalue [2 x i64] undef, i64 %c_offset_041, 0
  %c_offset_143 = load i64, ptr %c_offset_1, align 4
  %arr_ins_144 = insertvalue [2 x i64] %arr_ins_042, i64 %c_offset_143, 1
  %insert_OFFSET45 = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_PARENT40, [2 x i64] %arr_ins_144, 1
  %c_stride_046 = load i64, ptr %c_stride_0, align 4
  %arr_ins_047 = insertvalue [2 x i64] undef, i64 %c_stride_046, 0
  %c_stride_148 = load i64, ptr %c_stride_1, align 4
  %arr_ins_149 = insertvalue [2 x i64] %arr_ins_047, i64 %c_stride_148, 1
  %insert_STRIDES50 = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_OFFSET45, [2 x i64] %arr_ins_149, 2
  %c_extent_051 = load i64, ptr %c_extent_0, align 4
  %arr_ins_052 = insertvalue [2 x i64] undef, i64 %c_extent_051, 0
  %c_extent_153 = load i64, ptr %c_extent_1, align 4
  %arr_ins_154 = insertvalue [2 x i64] %arr_ins_052, i64 %c_extent_153, 1
  %insert_EXTENTS55 = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_STRIDES50, [2 x i64] %arr_ins_154, 3
  %c_length56 = load i64, ptr %c_length, align 4
  %insert_LENGTH57 = insertvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_EXTENTS55, i64 %c_length56, 4
  %c = alloca %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_LENGTH57, ptr %c, align 8
  %"c-tile$f0" = alloca %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, align 8
  store %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 zeroinitializer, ptr %"c-tile$f0", align 4
  %"c-tile$f1" = alloca %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, align 8
  store %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 zeroinitializer, ptr %"c-tile$f1", align 4
  %"c-tile$f058" = load %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %"c-tile$f0", align 4
  %subgrouplocalinvocationid = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane = alloca i32, align 4
  store i32 %subgrouplocalinvocationid, ptr %lane, align 4
  %lane59 = load i32, ptr %lane, align 4
  %iop_tmp = sdiv i32 %lane59, 4
  %g = alloca i32, align 4
  store i32 %iop_tmp, ptr %g, align 4
  %lane60 = load i32, ptr %lane, align 4
  %mod-x326 = alloca i32, align 4
  store i32 %lane60, ptr %mod-x326, align 4
  %mod-y327 = alloca i32, align 4
  store i32 4, ptr %mod-y327, align 4
  %mod-x32661 = load i32, ptr %mod-x326, align 4
  %mod-x32662 = load i32, ptr %mod-x326, align 4
  %mod-y32763 = load i32, ptr %mod-y327, align 4
  %iop_tmp64 = sdiv i32 %mod-x32662, %mod-y32763
  %mod-y32765 = load i32, ptr %mod-y327, align 4
  %iop_tmp66 = mul i32 %iop_tmp64, %mod-y32765
  %iop_tmp67 = sub i32 %mod-x32661, %iop_tmp66
  %tg = alloca i32, align 4
  store i32 %iop_tmp67, ptr %tg, align 4
  %g68 = load i32, ptr %g, align 4
  %iop_tmp69 = add i32 0, %g68
  %r = alloca i32, align 4
  store i32 %iop_tmp69, ptr %r, align 4
  %tg70 = load i32, ptr %tg, align 4
  %iop_tmp71 = add i32 0, %tg70
  %c72 = alloca i32, align 4
  store i32 %iop_tmp71, ptr %c72, align 4
  %r73 = load i32, ptr %r, align 4
  %sext_cast = sext i32 %r73 to i64
  %arr_field_ptr = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr = getelementptr inbounds [2 x i64], ptr %arr_field_ptr, i32 0, i64 1
  %arr_elem = load i64, ptr %arr_elem_ptr, align 4
  %iop_tmp74 = mul i64 %sext_cast, %arr_elem
  %c75 = load i32, ptr %c72, align 4
  %sext_cast76 = sext i32 %c75 to i64
  %iop_tmp77 = add i64 %iop_tmp74, %sext_cast76
  %a78 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a78, 0
  %t_base_ptr = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val, 0
  %t_byte_off = mul i64 %iop_tmp77, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr, i64 %t_byte_off
  %t_elem = load float, ptr addrspace(1) %t_ptr_i8, align 4, !invariant.load !1
  %insert_A0 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 undef, float %t_elem, 0
  %r79 = load i32, ptr %r, align 4
  %iop_tmp80 = add i32 %r79, 8
  %sext_cast81 = sext i32 %iop_tmp80 to i64
  %arr_field_ptr82 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr83 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr82, i32 0, i64 1
  %arr_elem84 = load i64, ptr %arr_elem_ptr83, align 4
  %iop_tmp85 = mul i64 %sext_cast81, %arr_elem84
  %c86 = load i32, ptr %c72, align 4
  %sext_cast87 = sext i32 %c86 to i64
  %iop_tmp88 = add i64 %iop_tmp85, %sext_cast87
  %a89 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val90 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a89, 0
  %t_base_ptr91 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val90, 0
  %t_byte_off92 = mul i64 %iop_tmp88, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i893 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr91, i64 %t_byte_off92
  %t_elem94 = load float, ptr addrspace(1) %t_ptr_i893, align 4, !invariant.load !1
  %insert_A1 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A0, float %t_elem94, 1
  %r95 = load i32, ptr %r, align 4
  %sext_cast96 = sext i32 %r95 to i64
  %arr_field_ptr97 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr98 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr97, i32 0, i64 1
  %arr_elem99 = load i64, ptr %arr_elem_ptr98, align 4
  %iop_tmp100 = mul i64 %sext_cast96, %arr_elem99
  %c101 = load i32, ptr %c72, align 4
  %iop_tmp102 = add i32 %c101, 4
  %sext_cast103 = sext i32 %iop_tmp102 to i64
  %iop_tmp104 = add i64 %iop_tmp100, %sext_cast103
  %a105 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val106 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a105, 0
  %t_base_ptr107 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val106, 0
  %t_byte_off108 = mul i64 %iop_tmp104, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8109 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr107, i64 %t_byte_off108
  %t_elem110 = load float, ptr addrspace(1) %t_ptr_i8109, align 4, !invariant.load !1
  %insert_A2 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A1, float %t_elem110, 2
  %r111 = load i32, ptr %r, align 4
  %iop_tmp112 = add i32 %r111, 8
  %sext_cast113 = sext i32 %iop_tmp112 to i64
  %arr_field_ptr114 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr115 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr114, i32 0, i64 1
  %arr_elem116 = load i64, ptr %arr_elem_ptr115, align 4
  %iop_tmp117 = mul i64 %sext_cast113, %arr_elem116
  %c118 = load i32, ptr %c72, align 4
  %iop_tmp119 = add i32 %c118, 4
  %sext_cast120 = sext i32 %iop_tmp119 to i64
  %iop_tmp121 = add i64 %iop_tmp117, %sext_cast120
  %a122 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val123 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a122, 0
  %t_base_ptr124 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val123, 0
  %t_byte_off125 = mul i64 %iop_tmp121, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8126 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr124, i64 %t_byte_off125
  %t_elem127 = load float, ptr addrspace(1) %t_ptr_i8126, align 4, !invariant.load !1
  %insert_A3 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A2, float %t_elem127, 3
  %subgrouplocalinvocationid128 = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane129 = alloca i32, align 4
  store i32 %subgrouplocalinvocationid128, ptr %lane129, align 4
  %lane130 = load i32, ptr %lane129, align 4
  %iop_tmp131 = sdiv i32 %lane130, 4
  %g132 = alloca i32, align 4
  store i32 %iop_tmp131, ptr %g132, align 4
  %lane133 = load i32, ptr %lane129, align 4
  %mod-x328 = alloca i32, align 4
  store i32 %lane133, ptr %mod-x328, align 4
  %mod-y329 = alloca i32, align 4
  store i32 4, ptr %mod-y329, align 4
  %mod-x328134 = load i32, ptr %mod-x328, align 4
  %mod-x328135 = load i32, ptr %mod-x328, align 4
  %mod-y329136 = load i32, ptr %mod-y329, align 4
  %iop_tmp137 = sdiv i32 %mod-x328135, %mod-y329136
  %mod-y329138 = load i32, ptr %mod-y329, align 4
  %iop_tmp139 = mul i32 %iop_tmp137, %mod-y329138
  %iop_tmp140 = sub i32 %mod-x328134, %iop_tmp139
  %tg141 = alloca i32, align 4
  store i32 %iop_tmp140, ptr %tg141, align 4
  %tg142 = load i32, ptr %tg141, align 4
  %iop_tmp143 = add i32 0, %tg142
  %r144 = alloca i32, align 4
  store i32 %iop_tmp143, ptr %r144, align 4
  %g145 = load i32, ptr %g132, align 4
  %iop_tmp146 = add i32 0, %g145
  %c147 = alloca i32, align 4
  store i32 %iop_tmp146, ptr %c147, align 4
  %r148 = load i32, ptr %r144, align 4
  %sext_cast149 = sext i32 %r148 to i64
  %arr_field_ptr150 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, i32 0, i32 3
  %arr_elem_ptr151 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr150, i32 0, i64 1
  %arr_elem152 = load i64, ptr %arr_elem_ptr151, align 4
  %iop_tmp153 = mul i64 %sext_cast149, %arr_elem152
  %c154 = load i32, ptr %c147, align 4
  %sext_cast155 = sext i32 %c154 to i64
  %iop_tmp156 = add i64 %iop_tmp153, %sext_cast155
  %b157 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, align 8
  %t_parent_val158 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %b157, 0
  %t_base_ptr159 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val158, 0
  %t_byte_off160 = mul i64 %iop_tmp156, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8161 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr159, i64 %t_byte_off160
  %t_elem162 = load float, ptr addrspace(1) %t_ptr_i8161, align 4, !invariant.load !1
  %insert_B0 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-B-TF32-8X8 undef, float %t_elem162, 0
  %r163 = load i32, ptr %r144, align 4
  %iop_tmp164 = add i32 %r163, 4
  %sext_cast165 = sext i32 %iop_tmp164 to i64
  %arr_field_ptr166 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, i32 0, i32 3
  %arr_elem_ptr167 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr166, i32 0, i64 1
  %arr_elem168 = load i64, ptr %arr_elem_ptr167, align 4
  %iop_tmp169 = mul i64 %sext_cast165, %arr_elem168
  %c170 = load i32, ptr %c147, align 4
  %sext_cast171 = sext i32 %c170 to i64
  %iop_tmp172 = add i64 %iop_tmp169, %sext_cast171
  %b173 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, align 8
  %t_parent_val174 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %b173, 0
  %t_base_ptr175 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val174, 0
  %t_byte_off176 = mul i64 %iop_tmp172, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8177 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr175, i64 %t_byte_off176
  %t_elem178 = load float, ptr addrspace(1) %t_ptr_i8177, align 4, !invariant.load !1
  %insert_B1 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B0, float %t_elem178, 1
  %a0 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, 0
  %a0i = bitcast float %a0 to i32
  %a1 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, 1
  %a1i = bitcast float %a1 to i32
  %a2 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, 2
  %a2i = bitcast float %a2 to i32
  %a3 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, 3
  %a3i = bitcast float %a3 to i32
  %b0 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B1, 0
  %b0i = bitcast float %b0 to i32
  %b1 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B1, 1
  %b1i = bitcast float %b1 to i32
  %c0 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f058", 0
  %c1 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f058", 1
  %c2 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f058", 2
  %c3 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f058", 3
  %mma = call { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32 %a0i, i32 %a1i, i32 %a2i, i32 %a3i, i32 %b0i, i32 %b1i, float %c0, float %c1, float %c2, float %c3)
  %d0 = extractvalue { float, float, float, float } %mma, 0
  %acc0 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 undef, float %d0, 0
  %d1 = extractvalue { float, float, float, float } %mma, 1
  %acc1 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %acc0, float %d1, 1
  %d2 = extractvalue { float, float, float, float } %mma, 2
  %acc2 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %acc1, float %d2, 2
  %d3 = extractvalue { float, float, float, float } %mma, 3
  %acc3 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %acc2, float %d3, 3
  store %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %acc3, ptr %"c-tile$f0", align 4
  %"c-tile$f1179" = load %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %"c-tile$f1", align 4
  %subgrouplocalinvocationid180 = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane181 = alloca i32, align 4
  store i32 %subgrouplocalinvocationid180, ptr %lane181, align 4
  %lane182 = load i32, ptr %lane181, align 4
  %iop_tmp183 = sdiv i32 %lane182, 4
  %g184 = alloca i32, align 4
  store i32 %iop_tmp183, ptr %g184, align 4
  %lane185 = load i32, ptr %lane181, align 4
  %mod-x330 = alloca i32, align 4
  store i32 %lane185, ptr %mod-x330, align 4
  %mod-y331 = alloca i32, align 4
  store i32 4, ptr %mod-y331, align 4
  %mod-x330186 = load i32, ptr %mod-x330, align 4
  %mod-x330187 = load i32, ptr %mod-x330, align 4
  %mod-y331188 = load i32, ptr %mod-y331, align 4
  %iop_tmp189 = sdiv i32 %mod-x330187, %mod-y331188
  %mod-y331190 = load i32, ptr %mod-y331, align 4
  %iop_tmp191 = mul i32 %iop_tmp189, %mod-y331190
  %iop_tmp192 = sub i32 %mod-x330186, %iop_tmp191
  %tg193 = alloca i32, align 4
  store i32 %iop_tmp192, ptr %tg193, align 4
  %g194 = load i32, ptr %g184, align 4
  %iop_tmp195 = add i32 0, %g194
  %r196 = alloca i32, align 4
  store i32 %iop_tmp195, ptr %r196, align 4
  %tg197 = load i32, ptr %tg193, align 4
  %iop_tmp198 = add i32 0, %tg197
  %c199 = alloca i32, align 4
  store i32 %iop_tmp198, ptr %c199, align 4
  %r200 = load i32, ptr %r196, align 4
  %sext_cast201 = sext i32 %r200 to i64
  %arr_field_ptr202 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr203 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr202, i32 0, i64 1
  %arr_elem204 = load i64, ptr %arr_elem_ptr203, align 4
  %iop_tmp205 = mul i64 %sext_cast201, %arr_elem204
  %c206 = load i32, ptr %c199, align 4
  %sext_cast207 = sext i32 %c206 to i64
  %iop_tmp208 = add i64 %iop_tmp205, %sext_cast207
  %a209 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val210 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a209, 0
  %t_base_ptr211 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val210, 0
  %t_byte_off212 = mul i64 %iop_tmp208, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8213 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr211, i64 %t_byte_off212
  %t_elem214 = load float, ptr addrspace(1) %t_ptr_i8213, align 4, !invariant.load !1
  %insert_A0215 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 undef, float %t_elem214, 0
  %r216 = load i32, ptr %r196, align 4
  %iop_tmp217 = add i32 %r216, 8
  %sext_cast218 = sext i32 %iop_tmp217 to i64
  %arr_field_ptr219 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr220 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr219, i32 0, i64 1
  %arr_elem221 = load i64, ptr %arr_elem_ptr220, align 4
  %iop_tmp222 = mul i64 %sext_cast218, %arr_elem221
  %c223 = load i32, ptr %c199, align 4
  %sext_cast224 = sext i32 %c223 to i64
  %iop_tmp225 = add i64 %iop_tmp222, %sext_cast224
  %a226 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val227 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a226, 0
  %t_base_ptr228 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val227, 0
  %t_byte_off229 = mul i64 %iop_tmp225, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8230 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr228, i64 %t_byte_off229
  %t_elem231 = load float, ptr addrspace(1) %t_ptr_i8230, align 4, !invariant.load !1
  %insert_A1232 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A0215, float %t_elem231, 1
  %r233 = load i32, ptr %r196, align 4
  %sext_cast234 = sext i32 %r233 to i64
  %arr_field_ptr235 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr236 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr235, i32 0, i64 1
  %arr_elem237 = load i64, ptr %arr_elem_ptr236, align 4
  %iop_tmp238 = mul i64 %sext_cast234, %arr_elem237
  %c239 = load i32, ptr %c199, align 4
  %iop_tmp240 = add i32 %c239, 4
  %sext_cast241 = sext i32 %iop_tmp240 to i64
  %iop_tmp242 = add i64 %iop_tmp238, %sext_cast241
  %a243 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val244 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a243, 0
  %t_base_ptr245 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val244, 0
  %t_byte_off246 = mul i64 %iop_tmp242, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8247 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr245, i64 %t_byte_off246
  %t_elem248 = load float, ptr addrspace(1) %t_ptr_i8247, align 4, !invariant.load !1
  %insert_A2249 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A1232, float %t_elem248, 2
  %r250 = load i32, ptr %r196, align 4
  %iop_tmp251 = add i32 %r250, 8
  %sext_cast252 = sext i32 %iop_tmp251 to i64
  %arr_field_ptr253 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr254 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr253, i32 0, i64 1
  %arr_elem255 = load i64, ptr %arr_elem_ptr254, align 4
  %iop_tmp256 = mul i64 %sext_cast252, %arr_elem255
  %c257 = load i32, ptr %c199, align 4
  %iop_tmp258 = add i32 %c257, 4
  %sext_cast259 = sext i32 %iop_tmp258 to i64
  %iop_tmp260 = add i64 %iop_tmp256, %sext_cast259
  %a261 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val262 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a261, 0
  %t_base_ptr263 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val262, 0
  %t_byte_off264 = mul i64 %iop_tmp260, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8265 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr263, i64 %t_byte_off264
  %t_elem266 = load float, ptr addrspace(1) %t_ptr_i8265, align 4, !invariant.load !1
  %insert_A3267 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A2249, float %t_elem266, 3
  %subgrouplocalinvocationid268 = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane269 = alloca i32, align 4
  store i32 %subgrouplocalinvocationid268, ptr %lane269, align 4
  %lane270 = load i32, ptr %lane269, align 4
  %iop_tmp271 = sdiv i32 %lane270, 4
  %g272 = alloca i32, align 4
  store i32 %iop_tmp271, ptr %g272, align 4
  %lane273 = load i32, ptr %lane269, align 4
  %mod-x332 = alloca i32, align 4
  store i32 %lane273, ptr %mod-x332, align 4
  %mod-y333 = alloca i32, align 4
  store i32 4, ptr %mod-y333, align 4
  %mod-x332274 = load i32, ptr %mod-x332, align 4
  %mod-x332275 = load i32, ptr %mod-x332, align 4
  %mod-y333276 = load i32, ptr %mod-y333, align 4
  %iop_tmp277 = sdiv i32 %mod-x332275, %mod-y333276
  %mod-y333278 = load i32, ptr %mod-y333, align 4
  %iop_tmp279 = mul i32 %iop_tmp277, %mod-y333278
  %iop_tmp280 = sub i32 %mod-x332274, %iop_tmp279
  %tg281 = alloca i32, align 4
  store i32 %iop_tmp280, ptr %tg281, align 4
  %tg282 = load i32, ptr %tg281, align 4
  %iop_tmp283 = add i32 0, %tg282
  %r284 = alloca i32, align 4
  store i32 %iop_tmp283, ptr %r284, align 4
  %g285 = load i32, ptr %g272, align 4
  %iop_tmp286 = add i32 8, %g285
  %c287 = alloca i32, align 4
  store i32 %iop_tmp286, ptr %c287, align 4
  %r288 = load i32, ptr %r284, align 4
  %sext_cast289 = sext i32 %r288 to i64
  %arr_field_ptr290 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, i32 0, i32 3
  %arr_elem_ptr291 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr290, i32 0, i64 1
  %arr_elem292 = load i64, ptr %arr_elem_ptr291, align 4
  %iop_tmp293 = mul i64 %sext_cast289, %arr_elem292
  %c294 = load i32, ptr %c287, align 4
  %sext_cast295 = sext i32 %c294 to i64
  %iop_tmp296 = add i64 %iop_tmp293, %sext_cast295
  %b297 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, align 8
  %t_parent_val298 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %b297, 0
  %t_base_ptr299 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val298, 0
  %t_byte_off300 = mul i64 %iop_tmp296, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8301 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr299, i64 %t_byte_off300
  %t_elem302 = load float, ptr addrspace(1) %t_ptr_i8301, align 4, !invariant.load !1
  %insert_B0303 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-B-TF32-8X8 undef, float %t_elem302, 0
  %r304 = load i32, ptr %r284, align 4
  %iop_tmp305 = add i32 %r304, 4
  %sext_cast306 = sext i32 %iop_tmp305 to i64
  %arr_field_ptr307 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, i32 0, i32 3
  %arr_elem_ptr308 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr307, i32 0, i64 1
  %arr_elem309 = load i64, ptr %arr_elem_ptr308, align 4
  %iop_tmp310 = mul i64 %sext_cast306, %arr_elem309
  %c311 = load i32, ptr %c287, align 4
  %sext_cast312 = sext i32 %c311 to i64
  %iop_tmp313 = add i64 %iop_tmp310, %sext_cast312
  %b314 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, align 8
  %t_parent_val315 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %b314, 0
  %t_base_ptr316 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val315, 0
  %t_byte_off317 = mul i64 %iop_tmp313, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8318 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr316, i64 %t_byte_off317
  %t_elem319 = load float, ptr addrspace(1) %t_ptr_i8318, align 4, !invariant.load !1
  %insert_B1320 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B0303, float %t_elem319, 1
  %a0321 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3267, 0
  %a0i322 = bitcast float %a0321 to i32
  %a1323 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3267, 1
  %a1i324 = bitcast float %a1323 to i32
  %a2325 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3267, 2
  %a2i326 = bitcast float %a2325 to i32
  %a3327 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3267, 3
  %a3i328 = bitcast float %a3327 to i32
  %b0329 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B1320, 0
  %b0i330 = bitcast float %b0329 to i32
  %b1331 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B1320, 1
  %b1i332 = bitcast float %b1331 to i32
  %c0333 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f1179", 0
  %c1334 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f1179", 1
  %c2335 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f1179", 2
  %c3336 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f1179", 3
  %mma337 = call { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32 %a0i322, i32 %a1i324, i32 %a2i326, i32 %a3i328, i32 %b0i330, i32 %b1i332, float %c0333, float %c1334, float %c2335, float %c3336)
  %d0338 = extractvalue { float, float, float, float } %mma337, 0
  %acc0339 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 undef, float %d0338, 0
  %d1340 = extractvalue { float, float, float, float } %mma337, 1
  %acc1341 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %acc0339, float %d1340, 1
  %d2342 = extractvalue { float, float, float, float } %mma337, 2
  %acc2343 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %acc1341, float %d2342, 2
  %d3344 = extractvalue { float, float, float, float } %mma337, 3
  %acc3345 = insertvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %acc2343, float %d3344, 3
  store %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %acc3345, ptr %"c-tile$f1", align 4
  %"c-tile$f0346" = load %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %"c-tile$f0", align 4
  %frag-val = alloca %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, align 8
  store %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f0346", ptr %frag-val, align 4
  %subgrouplocalinvocationid347 = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane348 = alloca i32, align 4
  store i32 %subgrouplocalinvocationid347, ptr %lane348, align 4
  %lane349 = load i32, ptr %lane348, align 4
  %iop_tmp350 = sdiv i32 %lane349, 4
  %g351 = alloca i32, align 4
  store i32 %iop_tmp350, ptr %g351, align 4
  %lane352 = load i32, ptr %lane348, align 4
  %mod-x334 = alloca i32, align 4
  store i32 %lane352, ptr %mod-x334, align 4
  %mod-y335 = alloca i32, align 4
  store i32 4, ptr %mod-y335, align 4
  %mod-x334353 = load i32, ptr %mod-x334, align 4
  %mod-x334354 = load i32, ptr %mod-x334, align 4
  %mod-y335355 = load i32, ptr %mod-y335, align 4
  %iop_tmp356 = sdiv i32 %mod-x334354, %mod-y335355
  %mod-y335357 = load i32, ptr %mod-y335, align 4
  %iop_tmp358 = mul i32 %iop_tmp356, %mod-y335357
  %iop_tmp359 = sub i32 %mod-x334353, %iop_tmp358
  %iop_tmp360 = mul i32 2, %iop_tmp359
  %t2 = alloca i32, align 4
  store i32 %iop_tmp360, ptr %t2, align 4
  %g361 = load i32, ptr %g351, align 4
  %iop_tmp362 = add i32 0, %g361
  %row = alloca i32, align 4
  store i32 %iop_tmp362, ptr %row, align 4
  %t2363 = load i32, ptr %t2, align 4
  %iop_tmp364 = add i32 0, %t2363
  %col = alloca i32, align 4
  store i32 %iop_tmp364, ptr %col, align 4
  %frag-val365 = load %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_0 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val365, 0
  %row366 = load i32, ptr %row, align 4
  %sext_cast367 = sext i32 %row366 to i64
  %arr_field_ptr368 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr369 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr368, i32 0, i64 1
  %arr_elem370 = load i64, ptr %arr_elem_ptr369, align 4
  %iop_tmp371 = mul i64 %sext_cast367, %arr_elem370
  %col372 = load i32, ptr %col, align 4
  %sext_cast373 = sext i32 %col372 to i64
  %iop_tmp374 = add i64 %iop_tmp371, %sext_cast373
  %c375 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val376 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c375, 0
  %t_base_ptr377 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val376, 0
  %t_byte_off378 = mul i64 %iop_tmp374, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8379 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr377, i64 %t_byte_off378
  %t_elem380 = load float, ptr addrspace(1) %t_ptr_i8379, align 4
  store float %extract_0, ptr addrspace(1) %t_ptr_i8379, align 4
  %frag-val381 = load %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_1 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val381, 1
  %row382 = load i32, ptr %row, align 4
  %sext_cast383 = sext i32 %row382 to i64
  %arr_field_ptr384 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr385 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr384, i32 0, i64 1
  %arr_elem386 = load i64, ptr %arr_elem_ptr385, align 4
  %iop_tmp387 = mul i64 %sext_cast383, %arr_elem386
  %col388 = load i32, ptr %col, align 4
  %iop_tmp389 = add i32 %col388, 1
  %sext_cast390 = sext i32 %iop_tmp389 to i64
  %iop_tmp391 = add i64 %iop_tmp387, %sext_cast390
  %c392 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val393 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c392, 0
  %t_base_ptr394 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val393, 0
  %t_byte_off395 = mul i64 %iop_tmp391, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8396 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr394, i64 %t_byte_off395
  %t_elem397 = load float, ptr addrspace(1) %t_ptr_i8396, align 4
  store float %extract_1, ptr addrspace(1) %t_ptr_i8396, align 4
  %frag-val398 = load %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_2 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val398, 2
  %row399 = load i32, ptr %row, align 4
  %iop_tmp400 = add i32 %row399, 8
  %sext_cast401 = sext i32 %iop_tmp400 to i64
  %arr_field_ptr402 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr403 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr402, i32 0, i64 1
  %arr_elem404 = load i64, ptr %arr_elem_ptr403, align 4
  %iop_tmp405 = mul i64 %sext_cast401, %arr_elem404
  %col406 = load i32, ptr %col, align 4
  %sext_cast407 = sext i32 %col406 to i64
  %iop_tmp408 = add i64 %iop_tmp405, %sext_cast407
  %c409 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val410 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c409, 0
  %t_base_ptr411 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val410, 0
  %t_byte_off412 = mul i64 %iop_tmp408, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8413 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr411, i64 %t_byte_off412
  %t_elem414 = load float, ptr addrspace(1) %t_ptr_i8413, align 4
  store float %extract_2, ptr addrspace(1) %t_ptr_i8413, align 4
  %frag-val415 = load %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_3 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val415, 3
  %row416 = load i32, ptr %row, align 4
  %iop_tmp417 = add i32 %row416, 8
  %sext_cast418 = sext i32 %iop_tmp417 to i64
  %arr_field_ptr419 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr420 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr419, i32 0, i64 1
  %arr_elem421 = load i64, ptr %arr_elem_ptr420, align 4
  %iop_tmp422 = mul i64 %sext_cast418, %arr_elem421
  %col423 = load i32, ptr %col, align 4
  %iop_tmp424 = add i32 %col423, 1
  %sext_cast425 = sext i32 %iop_tmp424 to i64
  %iop_tmp426 = add i64 %iop_tmp422, %sext_cast425
  %c427 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val428 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c427, 0
  %t_base_ptr429 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val428, 0
  %t_byte_off430 = mul i64 %iop_tmp426, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8431 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr429, i64 %t_byte_off430
  %t_elem432 = load float, ptr addrspace(1) %t_ptr_i8431, align 4
  store float %extract_3, ptr addrspace(1) %t_ptr_i8431, align 4
  %"c-tile$f1433" = load %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %"c-tile$f1", align 4
  %frag-val434 = alloca %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, align 8
  store %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f1433", ptr %frag-val434, align 4
  %subgrouplocalinvocationid435 = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane436 = alloca i32, align 4
  store i32 %subgrouplocalinvocationid435, ptr %lane436, align 4
  %lane437 = load i32, ptr %lane436, align 4
  %iop_tmp438 = sdiv i32 %lane437, 4
  %g439 = alloca i32, align 4
  store i32 %iop_tmp438, ptr %g439, align 4
  %lane440 = load i32, ptr %lane436, align 4
  %mod-x336 = alloca i32, align 4
  store i32 %lane440, ptr %mod-x336, align 4
  %mod-y337 = alloca i32, align 4
  store i32 4, ptr %mod-y337, align 4
  %mod-x336441 = load i32, ptr %mod-x336, align 4
  %mod-x336442 = load i32, ptr %mod-x336, align 4
  %mod-y337443 = load i32, ptr %mod-y337, align 4
  %iop_tmp444 = sdiv i32 %mod-x336442, %mod-y337443
  %mod-y337445 = load i32, ptr %mod-y337, align 4
  %iop_tmp446 = mul i32 %iop_tmp444, %mod-y337445
  %iop_tmp447 = sub i32 %mod-x336441, %iop_tmp446
  %iop_tmp448 = mul i32 2, %iop_tmp447
  %t2449 = alloca i32, align 4
  store i32 %iop_tmp448, ptr %t2449, align 4
  %g450 = load i32, ptr %g439, align 4
  %iop_tmp451 = add i32 0, %g450
  %row452 = alloca i32, align 4
  store i32 %iop_tmp451, ptr %row452, align 4
  %t2453 = load i32, ptr %t2449, align 4
  %iop_tmp454 = add i32 8, %t2453
  %col455 = alloca i32, align 4
  store i32 %iop_tmp454, ptr %col455, align 4
  %frag-val456 = load %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val434, align 4
  %extract_0457 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val456, 0
  %row458 = load i32, ptr %row452, align 4
  %sext_cast459 = sext i32 %row458 to i64
  %arr_field_ptr460 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr461 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr460, i32 0, i64 1
  %arr_elem462 = load i64, ptr %arr_elem_ptr461, align 4
  %iop_tmp463 = mul i64 %sext_cast459, %arr_elem462
  %col464 = load i32, ptr %col455, align 4
  %sext_cast465 = sext i32 %col464 to i64
  %iop_tmp466 = add i64 %iop_tmp463, %sext_cast465
  %c467 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val468 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c467, 0
  %t_base_ptr469 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val468, 0
  %t_byte_off470 = mul i64 %iop_tmp466, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8471 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr469, i64 %t_byte_off470
  %t_elem472 = load float, ptr addrspace(1) %t_ptr_i8471, align 4
  store float %extract_0457, ptr addrspace(1) %t_ptr_i8471, align 4
  %frag-val473 = load %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val434, align 4
  %extract_1474 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val473, 1
  %row475 = load i32, ptr %row452, align 4
  %sext_cast476 = sext i32 %row475 to i64
  %arr_field_ptr477 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr478 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr477, i32 0, i64 1
  %arr_elem479 = load i64, ptr %arr_elem_ptr478, align 4
  %iop_tmp480 = mul i64 %sext_cast476, %arr_elem479
  %col481 = load i32, ptr %col455, align 4
  %iop_tmp482 = add i32 %col481, 1
  %sext_cast483 = sext i32 %iop_tmp482 to i64
  %iop_tmp484 = add i64 %iop_tmp480, %sext_cast483
  %c485 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val486 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c485, 0
  %t_base_ptr487 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val486, 0
  %t_byte_off488 = mul i64 %iop_tmp484, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8489 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr487, i64 %t_byte_off488
  %t_elem490 = load float, ptr addrspace(1) %t_ptr_i8489, align 4
  store float %extract_1474, ptr addrspace(1) %t_ptr_i8489, align 4
  %frag-val491 = load %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val434, align 4
  %extract_2492 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val491, 2
  %row493 = load i32, ptr %row452, align 4
  %iop_tmp494 = add i32 %row493, 8
  %sext_cast495 = sext i32 %iop_tmp494 to i64
  %arr_field_ptr496 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr497 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr496, i32 0, i64 1
  %arr_elem498 = load i64, ptr %arr_elem_ptr497, align 4
  %iop_tmp499 = mul i64 %sext_cast495, %arr_elem498
  %col500 = load i32, ptr %col455, align 4
  %sext_cast501 = sext i32 %col500 to i64
  %iop_tmp502 = add i64 %iop_tmp499, %sext_cast501
  %c503 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val504 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c503, 0
  %t_base_ptr505 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val504, 0
  %t_byte_off506 = mul i64 %iop_tmp502, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8507 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr505, i64 %t_byte_off506
  %t_elem508 = load float, ptr addrspace(1) %t_ptr_i8507, align 4
  store float %extract_2492, ptr addrspace(1) %t_ptr_i8507, align 4
  %frag-val509 = load %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val434, align 4
  %extract_3510 = extractvalue %S_05_mma_via_tile_multi_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val509, 3
  %row511 = load i32, ptr %row452, align 4
  %iop_tmp512 = add i32 %row511, 8
  %sext_cast513 = sext i32 %iop_tmp512 to i64
  %arr_field_ptr514 = getelementptr inbounds %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr515 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr514, i32 0, i64 1
  %arr_elem516 = load i64, ptr %arr_elem_ptr515, align 4
  %iop_tmp517 = mul i64 %sext_cast513, %arr_elem516
  %col518 = load i32, ptr %col455, align 4
  %iop_tmp519 = add i32 %col518, 1
  %sext_cast520 = sext i32 %iop_tmp519 to i64
  %iop_tmp521 = add i64 %iop_tmp517, %sext_cast520
  %c522 = load %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val523 = extractvalue %S_05_mma_via_tile_multi_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c522, 0
  %t_base_ptr524 = extractvalue %S_05_mma_via_tile_multi_STORAGE_GLOBAL %t_parent_val523, 0
  %t_byte_off525 = mul i64 %iop_tmp521, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8526 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr524, i64 %t_byte_off525
  %t_elem527 = load float, ptr addrspace(1) %t_ptr_i8526, align 4
  store float %extract_3510, ptr addrspace(1) %t_ptr_i8526, align 4
  ret void
}

; Function Attrs: nocallback nounwind memory(none)
declare { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32, i32, i32, i32, i32, i32, float, float, float, float) #1

attributes #0 = { "denormal-fp-math"="ieee,ieee" "denormal-fp-math-f32"="ieee,ieee" }
attributes #1 = { nocallback nounwind memory(none) }

!spirv.ExecutionMode = !{!0}

!0 = !{ptr @via_tile_multi, i32 4459, i32 32}
!1 = !{}


!100 = !{i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0}
!101 = !{!"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none"}
!102 = !{!"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong"}
!103 = !{!"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong"}
!104 = !{!"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !""}
