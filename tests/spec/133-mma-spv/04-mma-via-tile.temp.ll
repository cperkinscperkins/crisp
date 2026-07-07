; ModuleID = '04-mma-via-tile'
source_filename = "04-mma-via-tile"
target triple = "spir64-unknown-unknown"

%S_04_mma_via_tile_STORAGE_GLOBAL = type { ptr addrspace(1), i64 }
%S_04_mma_via_tile_CELL_INT_GLOBAL = type { %S_04_mma_via_tile_STORAGE_GLOBAL, i64 }
%S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST = type { %S_04_mma_via_tile_STORAGE_GLOBAL, [2 x i64], [2 x i64], [2 x i64], i64 }
%S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST = type { %S_04_mma_via_tile_STORAGE_GLOBAL, [2 x i64], [2 x i64], [2 x i64], i64 }
%S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 = type { float, float, float, float }
%S_04_mma_via_tile_REGISTER-FRAGMENT-A-TF32-16X8 = type { float, float, float, float }
%S_04_mma_via_tile_REGISTER-FRAGMENT-B-TF32-8X8 = type { float, float }

@__spirv_BuiltInSubgroupLocalInvocationId = addrspace(1) global i32 0

define spir_func ptr addrspace(1) @address__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_04_mma_via_tile_STORAGE_GLOBAL, align 8
  store %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_04_mma_via_tile_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %obj1, 0
  ret ptr addrspace(1) %extract_0
}

define spir_func i64 @byte_size__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_04_mma_via_tile_STORAGE_GLOBAL, align 8
  store %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_04_mma_via_tile_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func i32 @address_space__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_04_mma_via_tile_STORAGE_GLOBAL, align 8
  store %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func ptr addrspace(1) @_address__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_04_mma_via_tile_STORAGE_GLOBAL, align 8
  store %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_04_mma_via_tile_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %obj1, 0
  ret ptr addrspace(1) %extract_0
}

define spir_func i64 @_byte_size__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_04_mma_via_tile_STORAGE_GLOBAL, align 8
  store %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_04_mma_via_tile_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func %S_04_mma_via_tile_STORAGE_GLOBAL @parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_CELL_INT_GLOBAL undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_04_mma_via_tile_CELL_INT_GLOBAL, align 8
  store %S_04_mma_via_tile_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_04_mma_via_tile_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_04_mma_via_tile_CELL_INT_GLOBAL %obj1, 0
  ret %S_04_mma_via_tile_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @offset__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_CELL_INT_GLOBAL undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_04_mma_via_tile_CELL_INT_GLOBAL, align 8
  store %S_04_mma_via_tile_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_04_mma_via_tile_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_04_mma_via_tile_CELL_INT_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func i32 @address_space__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_CELL_INT_GLOBAL undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_04_mma_via_tile_CELL_INT_GLOBAL, align 8
  store %S_04_mma_via_tile_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func %S_04_mma_via_tile_STORAGE_GLOBAL @_parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_CELL_INT_GLOBAL undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_04_mma_via_tile_CELL_INT_GLOBAL, align 8
  store %S_04_mma_via_tile_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_04_mma_via_tile_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_04_mma_via_tile_CELL_INT_GLOBAL %obj1, 0
  ret %S_04_mma_via_tile_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @_offset__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_CELL_INT_GLOBAL undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_04_mma_via_tile_CELL_INT_GLOBAL, align 8
  store %S_04_mma_via_tile_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_04_mma_via_tile_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_04_mma_via_tile_CELL_INT_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func %S_04_mma_via_tile_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 0
  ret %S_04_mma_via_tile_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @length__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 4
  ret i64 %extract_4
}

define spir_func i64 @num_dims__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i64 2
}

define spir_func i32 @address_space__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func i32 @align__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func i32 @contiguous_term__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func %S_04_mma_via_tile_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 0
  ret %S_04_mma_via_tile_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @_length__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 4
  ret i64 %extract_4
}

define spir_func %S_04_mma_via_tile_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_0 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 0
  ret %S_04_mma_via_tile_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @length__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_4 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 4
  ret i64 %extract_4
}

define spir_func i64 @num_dims__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i64 2
}

define spir_func i32 @address_space__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func i32 @align__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func i32 @contiguous_term__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func %S_04_mma_via_tile_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_0 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 0
  ret %S_04_mma_via_tile_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @_length__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_4 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 4
  ret i64 %extract_4
}

define spir_kernel void @via_tile(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8, ptr addrspace(1) %9, i64 %10, i64 %11, i64 %12, i64 %13, i64 %14, i64 %15, i64 %16, i64 %17, ptr addrspace(1) %18, i64 %19, i64 %20, i64 %21, i64 %22, i64 %23, i64 %24, i64 %25, i64 %26) !kernel_arg_addr_space !100 !kernel_arg_access_qual !101 !kernel_arg_type !102 !kernel_arg_base_type !103 !kernel_arg_type_qual !104 {
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
  %insert_ADDRESS = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %a_ptr1, 0
  %a_byte_size2 = load i64, ptr %a_byte_size, align 4
  %insert_BYTE-SIZE = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %insert_ADDRESS, i64 %a_byte_size2, 1
  %insert_PARENT = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %insert_BYTE-SIZE, 0
  %a_offset_03 = load i64, ptr %a_offset_0, align 4
  %arr_ins_0 = insertvalue [2 x i64] undef, i64 %a_offset_03, 0
  %a_offset_14 = load i64, ptr %a_offset_1, align 4
  %arr_ins_1 = insertvalue [2 x i64] %arr_ins_0, i64 %a_offset_14, 1
  %insert_OFFSET = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_PARENT, [2 x i64] %arr_ins_1, 1
  %a_stride_05 = load i64, ptr %a_stride_0, align 4
  %arr_ins_06 = insertvalue [2 x i64] undef, i64 %a_stride_05, 0
  %a_stride_17 = load i64, ptr %a_stride_1, align 4
  %arr_ins_18 = insertvalue [2 x i64] %arr_ins_06, i64 %a_stride_17, 1
  %insert_STRIDES = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_OFFSET, [2 x i64] %arr_ins_18, 2
  %a_extent_09 = load i64, ptr %a_extent_0, align 4
  %arr_ins_010 = insertvalue [2 x i64] undef, i64 %a_extent_09, 0
  %a_extent_111 = load i64, ptr %a_extent_1, align 4
  %arr_ins_112 = insertvalue [2 x i64] %arr_ins_010, i64 %a_extent_111, 1
  %insert_EXTENTS = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_STRIDES, [2 x i64] %arr_ins_112, 3
  %a_length13 = load i64, ptr %a_length, align 4
  %insert_LENGTH = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_EXTENTS, i64 %a_length13, 4
  %a = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_LENGTH, ptr %a, align 8
  %b_ptr14 = load ptr addrspace(1), ptr %b_ptr, align 8
  %insert_ADDRESS15 = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %b_ptr14, 0
  %b_byte_size16 = load i64, ptr %b_byte_size, align 4
  %insert_BYTE-SIZE17 = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %insert_ADDRESS15, i64 %b_byte_size16, 1
  %insert_PARENT18 = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %insert_BYTE-SIZE17, 0
  %b_offset_019 = load i64, ptr %b_offset_0, align 4
  %arr_ins_020 = insertvalue [2 x i64] undef, i64 %b_offset_019, 0
  %b_offset_121 = load i64, ptr %b_offset_1, align 4
  %arr_ins_122 = insertvalue [2 x i64] %arr_ins_020, i64 %b_offset_121, 1
  %insert_OFFSET23 = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_PARENT18, [2 x i64] %arr_ins_122, 1
  %b_stride_024 = load i64, ptr %b_stride_0, align 4
  %arr_ins_025 = insertvalue [2 x i64] undef, i64 %b_stride_024, 0
  %b_stride_126 = load i64, ptr %b_stride_1, align 4
  %arr_ins_127 = insertvalue [2 x i64] %arr_ins_025, i64 %b_stride_126, 1
  %insert_STRIDES28 = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_OFFSET23, [2 x i64] %arr_ins_127, 2
  %b_extent_029 = load i64, ptr %b_extent_0, align 4
  %arr_ins_030 = insertvalue [2 x i64] undef, i64 %b_extent_029, 0
  %b_extent_131 = load i64, ptr %b_extent_1, align 4
  %arr_ins_132 = insertvalue [2 x i64] %arr_ins_030, i64 %b_extent_131, 1
  %insert_EXTENTS33 = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_STRIDES28, [2 x i64] %arr_ins_132, 3
  %b_length34 = load i64, ptr %b_length, align 4
  %insert_LENGTH35 = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_EXTENTS33, i64 %b_length34, 4
  %b = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_LENGTH35, ptr %b, align 8
  %c_ptr36 = load ptr addrspace(1), ptr %c_ptr, align 8
  %insert_ADDRESS37 = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %c_ptr36, 0
  %c_byte_size38 = load i64, ptr %c_byte_size, align 4
  %insert_BYTE-SIZE39 = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %insert_ADDRESS37, i64 %c_byte_size38, 1
  %insert_PARENT40 = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_04_mma_via_tile_STORAGE_GLOBAL %insert_BYTE-SIZE39, 0
  %c_offset_041 = load i64, ptr %c_offset_0, align 4
  %arr_ins_042 = insertvalue [2 x i64] undef, i64 %c_offset_041, 0
  %c_offset_143 = load i64, ptr %c_offset_1, align 4
  %arr_ins_144 = insertvalue [2 x i64] %arr_ins_042, i64 %c_offset_143, 1
  %insert_OFFSET45 = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_PARENT40, [2 x i64] %arr_ins_144, 1
  %c_stride_046 = load i64, ptr %c_stride_0, align 4
  %arr_ins_047 = insertvalue [2 x i64] undef, i64 %c_stride_046, 0
  %c_stride_148 = load i64, ptr %c_stride_1, align 4
  %arr_ins_149 = insertvalue [2 x i64] %arr_ins_047, i64 %c_stride_148, 1
  %insert_STRIDES50 = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_OFFSET45, [2 x i64] %arr_ins_149, 2
  %c_extent_051 = load i64, ptr %c_extent_0, align 4
  %arr_ins_052 = insertvalue [2 x i64] undef, i64 %c_extent_051, 0
  %c_extent_153 = load i64, ptr %c_extent_1, align 4
  %arr_ins_154 = insertvalue [2 x i64] %arr_ins_052, i64 %c_extent_153, 1
  %insert_EXTENTS55 = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_STRIDES50, [2 x i64] %arr_ins_154, 3
  %c_length56 = load i64, ptr %c_length, align 4
  %insert_LENGTH57 = insertvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_EXTENTS55, i64 %c_length56, 4
  %c = alloca %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_LENGTH57, ptr %c, align 8
  %"c-tile$f0" = alloca %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8, align 8
  store %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 zeroinitializer, ptr %"c-tile$f0", align 4
  %"c-tile$f058" = load %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %"c-tile$f0", align 4
  %subgrouplocalinvocationid = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane = alloca i32, align 4
  store i32 %subgrouplocalinvocationid, ptr %lane, align 4
  %lane59 = load i32, ptr %lane, align 4
  %iop_tmp = sdiv i32 %lane59, 4
  %g = alloca i32, align 4
  store i32 %iop_tmp, ptr %g, align 4
  %lane60 = load i32, ptr %lane, align 4
  %mod-x304 = alloca i32, align 4
  store i32 %lane60, ptr %mod-x304, align 4
  %mod-y305 = alloca i32, align 4
  store i32 4, ptr %mod-y305, align 4
  %mod-x30461 = load i32, ptr %mod-x304, align 4
  %mod-x30462 = load i32, ptr %mod-x304, align 4
  %mod-y30563 = load i32, ptr %mod-y305, align 4
  %iop_tmp64 = sdiv i32 %mod-x30462, %mod-y30563
  %mod-y30565 = load i32, ptr %mod-y305, align 4
  %iop_tmp66 = mul i32 %iop_tmp64, %mod-y30565
  %iop_tmp67 = sub i32 %mod-x30461, %iop_tmp66
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
  %arr_field_ptr = getelementptr inbounds %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr = getelementptr inbounds [2 x i64], ptr %arr_field_ptr, i32 0, i64 1
  %arr_elem = load i64, ptr %arr_elem_ptr, align 4
  %iop_tmp74 = mul i64 %sext_cast, %arr_elem
  %c75 = load i32, ptr %c72, align 4
  %sext_cast76 = sext i32 %c75 to i64
  %iop_tmp77 = add i64 %iop_tmp74, %sext_cast76
  %a78 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a78, 0
  %t_base_ptr = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %t_parent_val, 0
  %t_byte_off = mul i64 %iop_tmp77, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr, i64 %t_byte_off
  %t_elem = load float, ptr addrspace(1) %t_ptr_i8, align 4, !invariant.load !1
  %insert_A0 = insertvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-A-TF32-16X8 undef, float %t_elem, 0
  %r79 = load i32, ptr %r, align 4
  %iop_tmp80 = add i32 %r79, 8
  %sext_cast81 = sext i32 %iop_tmp80 to i64
  %arr_field_ptr82 = getelementptr inbounds %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr83 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr82, i32 0, i64 1
  %arr_elem84 = load i64, ptr %arr_elem_ptr83, align 4
  %iop_tmp85 = mul i64 %sext_cast81, %arr_elem84
  %c86 = load i32, ptr %c72, align 4
  %sext_cast87 = sext i32 %c86 to i64
  %iop_tmp88 = add i64 %iop_tmp85, %sext_cast87
  %a89 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val90 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a89, 0
  %t_base_ptr91 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %t_parent_val90, 0
  %t_byte_off92 = mul i64 %iop_tmp88, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i893 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr91, i64 %t_byte_off92
  %t_elem94 = load float, ptr addrspace(1) %t_ptr_i893, align 4, !invariant.load !1
  %insert_A1 = insertvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A0, float %t_elem94, 1
  %r95 = load i32, ptr %r, align 4
  %sext_cast96 = sext i32 %r95 to i64
  %arr_field_ptr97 = getelementptr inbounds %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr98 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr97, i32 0, i64 1
  %arr_elem99 = load i64, ptr %arr_elem_ptr98, align 4
  %iop_tmp100 = mul i64 %sext_cast96, %arr_elem99
  %c101 = load i32, ptr %c72, align 4
  %iop_tmp102 = add i32 %c101, 4
  %sext_cast103 = sext i32 %iop_tmp102 to i64
  %iop_tmp104 = add i64 %iop_tmp100, %sext_cast103
  %a105 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val106 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a105, 0
  %t_base_ptr107 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %t_parent_val106, 0
  %t_byte_off108 = mul i64 %iop_tmp104, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8109 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr107, i64 %t_byte_off108
  %t_elem110 = load float, ptr addrspace(1) %t_ptr_i8109, align 4, !invariant.load !1
  %insert_A2 = insertvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A1, float %t_elem110, 2
  %r111 = load i32, ptr %r, align 4
  %iop_tmp112 = add i32 %r111, 8
  %sext_cast113 = sext i32 %iop_tmp112 to i64
  %arr_field_ptr114 = getelementptr inbounds %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr115 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr114, i32 0, i64 1
  %arr_elem116 = load i64, ptr %arr_elem_ptr115, align 4
  %iop_tmp117 = mul i64 %sext_cast113, %arr_elem116
  %c118 = load i32, ptr %c72, align 4
  %iop_tmp119 = add i32 %c118, 4
  %sext_cast120 = sext i32 %iop_tmp119 to i64
  %iop_tmp121 = add i64 %iop_tmp117, %sext_cast120
  %a122 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val123 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a122, 0
  %t_base_ptr124 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %t_parent_val123, 0
  %t_byte_off125 = mul i64 %iop_tmp121, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8126 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr124, i64 %t_byte_off125
  %t_elem127 = load float, ptr addrspace(1) %t_ptr_i8126, align 4, !invariant.load !1
  %insert_A3 = insertvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A2, float %t_elem127, 3
  %subgrouplocalinvocationid128 = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane129 = alloca i32, align 4
  store i32 %subgrouplocalinvocationid128, ptr %lane129, align 4
  %lane130 = load i32, ptr %lane129, align 4
  %iop_tmp131 = sdiv i32 %lane130, 4
  %g132 = alloca i32, align 4
  store i32 %iop_tmp131, ptr %g132, align 4
  %lane133 = load i32, ptr %lane129, align 4
  %mod-x306 = alloca i32, align 4
  store i32 %lane133, ptr %mod-x306, align 4
  %mod-y307 = alloca i32, align 4
  store i32 4, ptr %mod-y307, align 4
  %mod-x306134 = load i32, ptr %mod-x306, align 4
  %mod-x306135 = load i32, ptr %mod-x306, align 4
  %mod-y307136 = load i32, ptr %mod-y307, align 4
  %iop_tmp137 = sdiv i32 %mod-x306135, %mod-y307136
  %mod-y307138 = load i32, ptr %mod-y307, align 4
  %iop_tmp139 = mul i32 %iop_tmp137, %mod-y307138
  %iop_tmp140 = sub i32 %mod-x306134, %iop_tmp139
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
  %arr_field_ptr150 = getelementptr inbounds %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, i32 0, i32 3
  %arr_elem_ptr151 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr150, i32 0, i64 1
  %arr_elem152 = load i64, ptr %arr_elem_ptr151, align 4
  %iop_tmp153 = mul i64 %sext_cast149, %arr_elem152
  %c154 = load i32, ptr %c147, align 4
  %sext_cast155 = sext i32 %c154 to i64
  %iop_tmp156 = add i64 %iop_tmp153, %sext_cast155
  %b157 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, align 8
  %t_parent_val158 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %b157, 0
  %t_base_ptr159 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %t_parent_val158, 0
  %t_byte_off160 = mul i64 %iop_tmp156, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8161 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr159, i64 %t_byte_off160
  %t_elem162 = load float, ptr addrspace(1) %t_ptr_i8161, align 4, !invariant.load !1
  %insert_B0 = insertvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-B-TF32-8X8 undef, float %t_elem162, 0
  %r163 = load i32, ptr %r144, align 4
  %iop_tmp164 = add i32 %r163, 4
  %sext_cast165 = sext i32 %iop_tmp164 to i64
  %arr_field_ptr166 = getelementptr inbounds %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, i32 0, i32 3
  %arr_elem_ptr167 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr166, i32 0, i64 1
  %arr_elem168 = load i64, ptr %arr_elem_ptr167, align 4
  %iop_tmp169 = mul i64 %sext_cast165, %arr_elem168
  %c170 = load i32, ptr %c147, align 4
  %sext_cast171 = sext i32 %c170 to i64
  %iop_tmp172 = add i64 %iop_tmp169, %sext_cast171
  %b173 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, align 8
  %t_parent_val174 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %b173, 0
  %t_base_ptr175 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %t_parent_val174, 0
  %t_byte_off176 = mul i64 %iop_tmp172, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8177 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr175, i64 %t_byte_off176
  %t_elem178 = load float, ptr addrspace(1) %t_ptr_i8177, align 4, !invariant.load !1
  %insert_B1 = insertvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B0, float %t_elem178, 1
  %a0 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, 0
  %a0i = bitcast float %a0 to i32
  %a1 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, 1
  %a1i = bitcast float %a1 to i32
  %a2 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, 2
  %a2i = bitcast float %a2 to i32
  %a3 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, 3
  %a3i = bitcast float %a3 to i32
  %b0 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B1, 0
  %b0i = bitcast float %b0 to i32
  %b1 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B1, 1
  %b1i = bitcast float %b1 to i32
  %c0 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f058", 0
  %c1 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f058", 1
  %c2 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f058", 2
  %c3 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f058", 3
  %mma = call { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32 %a0i, i32 %a1i, i32 %a2i, i32 %a3i, i32 %b0i, i32 %b1i, float %c0, float %c1, float %c2, float %c3)
  %d0 = extractvalue { float, float, float, float } %mma, 0
  %acc0 = insertvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 undef, float %d0, 0
  %d1 = extractvalue { float, float, float, float } %mma, 1
  %acc1 = insertvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %acc0, float %d1, 1
  %d2 = extractvalue { float, float, float, float } %mma, 2
  %acc2 = insertvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %acc1, float %d2, 2
  %d3 = extractvalue { float, float, float, float } %mma, 3
  %acc3 = insertvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %acc2, float %d3, 3
  store %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %acc3, ptr %"c-tile$f0", align 4
  %"c-tile$f0179" = load %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %"c-tile$f0", align 4
  %frag-val = alloca %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8, align 8
  store %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %"c-tile$f0179", ptr %frag-val, align 4
  %subgrouplocalinvocationid180 = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane181 = alloca i32, align 4
  store i32 %subgrouplocalinvocationid180, ptr %lane181, align 4
  %lane182 = load i32, ptr %lane181, align 4
  %iop_tmp183 = sdiv i32 %lane182, 4
  %g184 = alloca i32, align 4
  store i32 %iop_tmp183, ptr %g184, align 4
  %lane185 = load i32, ptr %lane181, align 4
  %mod-x308 = alloca i32, align 4
  store i32 %lane185, ptr %mod-x308, align 4
  %mod-y309 = alloca i32, align 4
  store i32 4, ptr %mod-y309, align 4
  %mod-x308186 = load i32, ptr %mod-x308, align 4
  %mod-x308187 = load i32, ptr %mod-x308, align 4
  %mod-y309188 = load i32, ptr %mod-y309, align 4
  %iop_tmp189 = sdiv i32 %mod-x308187, %mod-y309188
  %mod-y309190 = load i32, ptr %mod-y309, align 4
  %iop_tmp191 = mul i32 %iop_tmp189, %mod-y309190
  %iop_tmp192 = sub i32 %mod-x308186, %iop_tmp191
  %iop_tmp193 = mul i32 2, %iop_tmp192
  %t2 = alloca i32, align 4
  store i32 %iop_tmp193, ptr %t2, align 4
  %g194 = load i32, ptr %g184, align 4
  %iop_tmp195 = add i32 0, %g194
  %row = alloca i32, align 4
  store i32 %iop_tmp195, ptr %row, align 4
  %t2196 = load i32, ptr %t2, align 4
  %iop_tmp197 = add i32 0, %t2196
  %col = alloca i32, align 4
  store i32 %iop_tmp197, ptr %col, align 4
  %frag-val198 = load %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_0 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val198, 0
  %row199 = load i32, ptr %row, align 4
  %sext_cast200 = sext i32 %row199 to i64
  %arr_field_ptr201 = getelementptr inbounds %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr202 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr201, i32 0, i64 1
  %arr_elem203 = load i64, ptr %arr_elem_ptr202, align 4
  %iop_tmp204 = mul i64 %sext_cast200, %arr_elem203
  %col205 = load i32, ptr %col, align 4
  %sext_cast206 = sext i32 %col205 to i64
  %iop_tmp207 = add i64 %iop_tmp204, %sext_cast206
  %c208 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val209 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c208, 0
  %t_base_ptr210 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %t_parent_val209, 0
  %t_byte_off211 = mul i64 %iop_tmp207, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8212 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr210, i64 %t_byte_off211
  %t_elem213 = load float, ptr addrspace(1) %t_ptr_i8212, align 4
  store float %extract_0, ptr addrspace(1) %t_ptr_i8212, align 4
  %frag-val214 = load %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_1 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val214, 1
  %row215 = load i32, ptr %row, align 4
  %sext_cast216 = sext i32 %row215 to i64
  %arr_field_ptr217 = getelementptr inbounds %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr218 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr217, i32 0, i64 1
  %arr_elem219 = load i64, ptr %arr_elem_ptr218, align 4
  %iop_tmp220 = mul i64 %sext_cast216, %arr_elem219
  %col221 = load i32, ptr %col, align 4
  %iop_tmp222 = add i32 %col221, 1
  %sext_cast223 = sext i32 %iop_tmp222 to i64
  %iop_tmp224 = add i64 %iop_tmp220, %sext_cast223
  %c225 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val226 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c225, 0
  %t_base_ptr227 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %t_parent_val226, 0
  %t_byte_off228 = mul i64 %iop_tmp224, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8229 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr227, i64 %t_byte_off228
  %t_elem230 = load float, ptr addrspace(1) %t_ptr_i8229, align 4
  store float %extract_1, ptr addrspace(1) %t_ptr_i8229, align 4
  %frag-val231 = load %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_2 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val231, 2
  %row232 = load i32, ptr %row, align 4
  %iop_tmp233 = add i32 %row232, 8
  %sext_cast234 = sext i32 %iop_tmp233 to i64
  %arr_field_ptr235 = getelementptr inbounds %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr236 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr235, i32 0, i64 1
  %arr_elem237 = load i64, ptr %arr_elem_ptr236, align 4
  %iop_tmp238 = mul i64 %sext_cast234, %arr_elem237
  %col239 = load i32, ptr %col, align 4
  %sext_cast240 = sext i32 %col239 to i64
  %iop_tmp241 = add i64 %iop_tmp238, %sext_cast240
  %c242 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val243 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c242, 0
  %t_base_ptr244 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %t_parent_val243, 0
  %t_byte_off245 = mul i64 %iop_tmp241, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8246 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr244, i64 %t_byte_off245
  %t_elem247 = load float, ptr addrspace(1) %t_ptr_i8246, align 4
  store float %extract_2, ptr addrspace(1) %t_ptr_i8246, align 4
  %frag-val248 = load %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_3 = extractvalue %S_04_mma_via_tile_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val248, 3
  %row249 = load i32, ptr %row, align 4
  %iop_tmp250 = add i32 %row249, 8
  %sext_cast251 = sext i32 %iop_tmp250 to i64
  %arr_field_ptr252 = getelementptr inbounds %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr253 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr252, i32 0, i64 1
  %arr_elem254 = load i64, ptr %arr_elem_ptr253, align 4
  %iop_tmp255 = mul i64 %sext_cast251, %arr_elem254
  %col256 = load i32, ptr %col, align 4
  %iop_tmp257 = add i32 %col256, 1
  %sext_cast258 = sext i32 %iop_tmp257 to i64
  %iop_tmp259 = add i64 %iop_tmp255, %sext_cast258
  %c260 = load %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val261 = extractvalue %S_04_mma_via_tile_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c260, 0
  %t_base_ptr262 = extractvalue %S_04_mma_via_tile_STORAGE_GLOBAL %t_parent_val261, 0
  %t_byte_off263 = mul i64 %iop_tmp259, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8264 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr262, i64 %t_byte_off263
  %t_elem265 = load float, ptr addrspace(1) %t_ptr_i8264, align 4
  store float %extract_3, ptr addrspace(1) %t_ptr_i8264, align 4
  ret void
}

; Function Attrs: nocallback nounwind memory(none)
declare { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32, i32, i32, i32, i32, i32, float, float, float, float) #1

attributes #0 = { "denormal-fp-math"="ieee,ieee" "denormal-fp-math-f32"="ieee,ieee" }
attributes #1 = { nocallback nounwind memory(none) }

!spirv.ExecutionMode = !{!0}

!0 = !{ptr @via_tile, i32 4459, i32 32}
!1 = !{}


!100 = !{i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0}
!101 = !{!"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none"}
!102 = !{!"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong"}
!103 = !{!"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong"}
!104 = !{!"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !""}
