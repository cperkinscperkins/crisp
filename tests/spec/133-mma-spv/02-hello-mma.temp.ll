; ModuleID = '02-hello-mma'
source_filename = "02-hello-mma"
target triple = "spir64-unknown-unknown"

%S_02_hello_mma_STORAGE_GLOBAL = type { ptr addrspace(1), i64 }
%S_02_hello_mma_CELL_INT_GLOBAL = type { %S_02_hello_mma_STORAGE_GLOBAL, i64 }
%S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST = type { %S_02_hello_mma_STORAGE_GLOBAL, [2 x i64], [2 x i64], [2 x i64], i64 }
%S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST = type { %S_02_hello_mma_STORAGE_GLOBAL, [2 x i64], [2 x i64], [2 x i64], i64 }
%S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 = type { float, float, float, float }
%S_02_hello_mma_REGISTER-FRAGMENT-A-TF32-16X8 = type { float, float, float, float }
%S_02_hello_mma_REGISTER-FRAGMENT-B-TF32-8X8 = type { float, float }

@__spirv_BuiltInSubgroupLocalInvocationId = addrspace(1) global i32 0

define spir_func ptr addrspace(1) @address__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_02_hello_mma_STORAGE_GLOBAL, align 8
  store %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_02_hello_mma_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %obj1, 0
  ret ptr addrspace(1) %extract_0
}

define spir_func i64 @byte_size__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_02_hello_mma_STORAGE_GLOBAL, align 8
  store %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_02_hello_mma_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func i32 @address_space__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_02_hello_mma_STORAGE_GLOBAL, align 8
  store %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func ptr addrspace(1) @_address__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_02_hello_mma_STORAGE_GLOBAL, align 8
  store %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_02_hello_mma_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %obj1, 0
  ret ptr addrspace(1) %extract_0
}

define spir_func i64 @_byte_size__storage_global(ptr addrspace(1) %0, i64 %1) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %S_02_hello_mma_STORAGE_GLOBAL, align 8
  store %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %S_02_hello_mma_STORAGE_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func %S_02_hello_mma_STORAGE_GLOBAL @parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_CELL_INT_GLOBAL undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_02_hello_mma_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_02_hello_mma_CELL_INT_GLOBAL, align 8
  store %S_02_hello_mma_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_02_hello_mma_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_02_hello_mma_CELL_INT_GLOBAL %obj1, 0
  ret %S_02_hello_mma_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @offset__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_CELL_INT_GLOBAL undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_02_hello_mma_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_02_hello_mma_CELL_INT_GLOBAL, align 8
  store %S_02_hello_mma_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_02_hello_mma_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_02_hello_mma_CELL_INT_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func i32 @address_space__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_CELL_INT_GLOBAL undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_02_hello_mma_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_02_hello_mma_CELL_INT_GLOBAL, align 8
  store %S_02_hello_mma_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func %S_02_hello_mma_STORAGE_GLOBAL @_parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_CELL_INT_GLOBAL undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_02_hello_mma_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_02_hello_mma_CELL_INT_GLOBAL, align 8
  store %S_02_hello_mma_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_02_hello_mma_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %S_02_hello_mma_CELL_INT_GLOBAL %obj1, 0
  ret %S_02_hello_mma_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @_offset__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_CELL_INT_GLOBAL undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %S_02_hello_mma_CELL_INT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %S_02_hello_mma_CELL_INT_GLOBAL, align 8
  store %S_02_hello_mma_CELL_INT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %S_02_hello_mma_CELL_INT_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %S_02_hello_mma_CELL_INT_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define spir_func %S_02_hello_mma_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 0
  ret %S_02_hello_mma_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @length__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 4
  ret i64 %extract_4
}

define spir_func i64 @num_dims__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i64 2
}

define spir_func i32 @address_space__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func i32 @align__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func i32 @contiguous_term__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func %S_02_hello_mma_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 0
  ret %S_02_hello_mma_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @_length__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %obj5, 4
  ret i64 %extract_4
}

define spir_func %S_02_hello_mma_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_0 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 0
  ret %S_02_hello_mma_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @length__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_4 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 4
  ret i64 %extract_4
}

define spir_func i64 @num_dims__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i64 2
}

define spir_func i32 @address_space__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func i32 @align__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define spir_func i32 @contiguous_term__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define spir_func %S_02_hello_mma_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_0 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 0
  ret %S_02_hello_mma_STORAGE_GLOBAL %extract_0
}

define spir_func i64 @_length__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %obj, align 8
  %extract_4 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %obj5, 4
  ret i64 %extract_4
}

define spir_kernel void @hello_mma(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8, ptr addrspace(1) %9, i64 %10, i64 %11, i64 %12, i64 %13, i64 %14, i64 %15, i64 %16, i64 %17, ptr addrspace(1) %18, i64 %19, i64 %20, i64 %21, i64 %22, i64 %23, i64 %24, i64 %25, i64 %26) !kernel_arg_addr_space !100 !kernel_arg_access_qual !101 !kernel_arg_type !102 !kernel_arg_base_type !103 !kernel_arg_type_qual !104 {
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
  %insert_ADDRESS = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %a_ptr1, 0
  %a_byte_size2 = load i64, ptr %a_byte_size, align 4
  %insert_BYTE-SIZE = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %insert_ADDRESS, i64 %a_byte_size2, 1
  %insert_PARENT = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_02_hello_mma_STORAGE_GLOBAL %insert_BYTE-SIZE, 0
  %a_offset_03 = load i64, ptr %a_offset_0, align 4
  %arr_ins_0 = insertvalue [2 x i64] undef, i64 %a_offset_03, 0
  %a_offset_14 = load i64, ptr %a_offset_1, align 4
  %arr_ins_1 = insertvalue [2 x i64] %arr_ins_0, i64 %a_offset_14, 1
  %insert_OFFSET = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_PARENT, [2 x i64] %arr_ins_1, 1
  %a_stride_05 = load i64, ptr %a_stride_0, align 4
  %arr_ins_06 = insertvalue [2 x i64] undef, i64 %a_stride_05, 0
  %a_stride_17 = load i64, ptr %a_stride_1, align 4
  %arr_ins_18 = insertvalue [2 x i64] %arr_ins_06, i64 %a_stride_17, 1
  %insert_STRIDES = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_OFFSET, [2 x i64] %arr_ins_18, 2
  %a_extent_09 = load i64, ptr %a_extent_0, align 4
  %arr_ins_010 = insertvalue [2 x i64] undef, i64 %a_extent_09, 0
  %a_extent_111 = load i64, ptr %a_extent_1, align 4
  %arr_ins_112 = insertvalue [2 x i64] %arr_ins_010, i64 %a_extent_111, 1
  %insert_EXTENTS = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_STRIDES, [2 x i64] %arr_ins_112, 3
  %a_length13 = load i64, ptr %a_length, align 4
  %insert_LENGTH = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_EXTENTS, i64 %a_length13, 4
  %a = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_LENGTH, ptr %a, align 8
  %b_ptr14 = load ptr addrspace(1), ptr %b_ptr, align 8
  %insert_ADDRESS15 = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %b_ptr14, 0
  %b_byte_size16 = load i64, ptr %b_byte_size, align 4
  %insert_BYTE-SIZE17 = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %insert_ADDRESS15, i64 %b_byte_size16, 1
  %insert_PARENT18 = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST undef, %S_02_hello_mma_STORAGE_GLOBAL %insert_BYTE-SIZE17, 0
  %b_offset_019 = load i64, ptr %b_offset_0, align 4
  %arr_ins_020 = insertvalue [2 x i64] undef, i64 %b_offset_019, 0
  %b_offset_121 = load i64, ptr %b_offset_1, align 4
  %arr_ins_122 = insertvalue [2 x i64] %arr_ins_020, i64 %b_offset_121, 1
  %insert_OFFSET23 = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_PARENT18, [2 x i64] %arr_ins_122, 1
  %b_stride_024 = load i64, ptr %b_stride_0, align 4
  %arr_ins_025 = insertvalue [2 x i64] undef, i64 %b_stride_024, 0
  %b_stride_126 = load i64, ptr %b_stride_1, align 4
  %arr_ins_127 = insertvalue [2 x i64] %arr_ins_025, i64 %b_stride_126, 1
  %insert_STRIDES28 = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_OFFSET23, [2 x i64] %arr_ins_127, 2
  %b_extent_029 = load i64, ptr %b_extent_0, align 4
  %arr_ins_030 = insertvalue [2 x i64] undef, i64 %b_extent_029, 0
  %b_extent_131 = load i64, ptr %b_extent_1, align 4
  %arr_ins_132 = insertvalue [2 x i64] %arr_ins_030, i64 %b_extent_131, 1
  %insert_EXTENTS33 = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_STRIDES28, [2 x i64] %arr_ins_132, 3
  %b_length34 = load i64, ptr %b_length, align 4
  %insert_LENGTH35 = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_EXTENTS33, i64 %b_length34, 4
  %b = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %insert_LENGTH35, ptr %b, align 8
  %c_ptr36 = load ptr addrspace(1), ptr %c_ptr, align 8
  %insert_ADDRESS37 = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %c_ptr36, 0
  %c_byte_size38 = load i64, ptr %c_byte_size, align 4
  %insert_BYTE-SIZE39 = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %insert_ADDRESS37, i64 %c_byte_size38, 1
  %insert_PARENT40 = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST undef, %S_02_hello_mma_STORAGE_GLOBAL %insert_BYTE-SIZE39, 0
  %c_offset_041 = load i64, ptr %c_offset_0, align 4
  %arr_ins_042 = insertvalue [2 x i64] undef, i64 %c_offset_041, 0
  %c_offset_143 = load i64, ptr %c_offset_1, align 4
  %arr_ins_144 = insertvalue [2 x i64] %arr_ins_042, i64 %c_offset_143, 1
  %insert_OFFSET45 = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_PARENT40, [2 x i64] %arr_ins_144, 1
  %c_stride_046 = load i64, ptr %c_stride_0, align 4
  %arr_ins_047 = insertvalue [2 x i64] undef, i64 %c_stride_046, 0
  %c_stride_148 = load i64, ptr %c_stride_1, align 4
  %arr_ins_149 = insertvalue [2 x i64] %arr_ins_047, i64 %c_stride_148, 1
  %insert_STRIDES50 = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_OFFSET45, [2 x i64] %arr_ins_149, 2
  %c_extent_051 = load i64, ptr %c_extent_0, align 4
  %arr_ins_052 = insertvalue [2 x i64] undef, i64 %c_extent_051, 0
  %c_extent_153 = load i64, ptr %c_extent_1, align 4
  %arr_ins_154 = insertvalue [2 x i64] %arr_ins_052, i64 %c_extent_153, 1
  %insert_EXTENTS55 = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_STRIDES50, [2 x i64] %arr_ins_154, 3
  %c_length56 = load i64, ptr %c_length, align 4
  %insert_LENGTH57 = insertvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_EXTENTS55, i64 %c_length56, 4
  %c = alloca %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, align 8
  store %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %insert_LENGTH57, ptr %c, align 8
  %c-acc = alloca %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8, align 8
  store %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 zeroinitializer, ptr %c-acc, align 4
  %subgrouplocalinvocationid = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane = alloca i32, align 4
  store i32 %subgrouplocalinvocationid, ptr %lane, align 4
  %lane58 = load i32, ptr %lane, align 4
  %iop_tmp = sdiv i32 %lane58, 4
  %g = alloca i32, align 4
  store i32 %iop_tmp, ptr %g, align 4
  %lane59 = load i32, ptr %lane, align 4
  %mod-x258 = alloca i32, align 4
  store i32 %lane59, ptr %mod-x258, align 4
  %mod-y259 = alloca i32, align 4
  store i32 4, ptr %mod-y259, align 4
  %mod-x25860 = load i32, ptr %mod-x258, align 4
  %mod-x25861 = load i32, ptr %mod-x258, align 4
  %mod-y25962 = load i32, ptr %mod-y259, align 4
  %iop_tmp63 = sdiv i32 %mod-x25861, %mod-y25962
  %mod-y25964 = load i32, ptr %mod-y259, align 4
  %iop_tmp65 = mul i32 %iop_tmp63, %mod-y25964
  %iop_tmp66 = sub i32 %mod-x25860, %iop_tmp65
  %tg = alloca i32, align 4
  store i32 %iop_tmp66, ptr %tg, align 4
  %g67 = load i32, ptr %g, align 4
  %iop_tmp68 = add i32 0, %g67
  %r = alloca i32, align 4
  store i32 %iop_tmp68, ptr %r, align 4
  %tg69 = load i32, ptr %tg, align 4
  %iop_tmp70 = add i32 0, %tg69
  %c71 = alloca i32, align 4
  store i32 %iop_tmp70, ptr %c71, align 4
  %r72 = load i32, ptr %r, align 4
  %sext_cast = sext i32 %r72 to i64
  %arr_field_ptr = getelementptr inbounds %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr = getelementptr inbounds [2 x i64], ptr %arr_field_ptr, i32 0, i64 1
  %arr_elem = load i64, ptr %arr_elem_ptr, align 4
  %iop_tmp73 = mul i64 %sext_cast, %arr_elem
  %c74 = load i32, ptr %c71, align 4
  %sext_cast75 = sext i32 %c74 to i64
  %iop_tmp76 = add i64 %iop_tmp73, %sext_cast75
  %a77 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a77, 0
  %t_base_ptr = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %t_parent_val, 0
  %t_byte_off = mul i64 %iop_tmp76, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr, i64 %t_byte_off
  %t_elem = load float, ptr addrspace(1) %t_ptr_i8, align 4, !invariant.load !1
  %insert_A0 = insertvalue %S_02_hello_mma_REGISTER-FRAGMENT-A-TF32-16X8 undef, float %t_elem, 0
  %r78 = load i32, ptr %r, align 4
  %iop_tmp79 = add i32 %r78, 8
  %sext_cast80 = sext i32 %iop_tmp79 to i64
  %arr_field_ptr81 = getelementptr inbounds %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr82 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr81, i32 0, i64 1
  %arr_elem83 = load i64, ptr %arr_elem_ptr82, align 4
  %iop_tmp84 = mul i64 %sext_cast80, %arr_elem83
  %c85 = load i32, ptr %c71, align 4
  %sext_cast86 = sext i32 %c85 to i64
  %iop_tmp87 = add i64 %iop_tmp84, %sext_cast86
  %a88 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val89 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a88, 0
  %t_base_ptr90 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %t_parent_val89, 0
  %t_byte_off91 = mul i64 %iop_tmp87, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i892 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr90, i64 %t_byte_off91
  %t_elem93 = load float, ptr addrspace(1) %t_ptr_i892, align 4, !invariant.load !1
  %insert_A1 = insertvalue %S_02_hello_mma_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A0, float %t_elem93, 1
  %r94 = load i32, ptr %r, align 4
  %sext_cast95 = sext i32 %r94 to i64
  %arr_field_ptr96 = getelementptr inbounds %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr97 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr96, i32 0, i64 1
  %arr_elem98 = load i64, ptr %arr_elem_ptr97, align 4
  %iop_tmp99 = mul i64 %sext_cast95, %arr_elem98
  %c100 = load i32, ptr %c71, align 4
  %iop_tmp101 = add i32 %c100, 4
  %sext_cast102 = sext i32 %iop_tmp101 to i64
  %iop_tmp103 = add i64 %iop_tmp99, %sext_cast102
  %a104 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val105 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a104, 0
  %t_base_ptr106 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %t_parent_val105, 0
  %t_byte_off107 = mul i64 %iop_tmp103, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8108 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr106, i64 %t_byte_off107
  %t_elem109 = load float, ptr addrspace(1) %t_ptr_i8108, align 4, !invariant.load !1
  %insert_A2 = insertvalue %S_02_hello_mma_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A1, float %t_elem109, 2
  %r110 = load i32, ptr %r, align 4
  %iop_tmp111 = add i32 %r110, 8
  %sext_cast112 = sext i32 %iop_tmp111 to i64
  %arr_field_ptr113 = getelementptr inbounds %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, i32 0, i32 3
  %arr_elem_ptr114 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr113, i32 0, i64 1
  %arr_elem115 = load i64, ptr %arr_elem_ptr114, align 4
  %iop_tmp116 = mul i64 %sext_cast112, %arr_elem115
  %c117 = load i32, ptr %c71, align 4
  %iop_tmp118 = add i32 %c117, 4
  %sext_cast119 = sext i32 %iop_tmp118 to i64
  %iop_tmp120 = add i64 %iop_tmp116, %sext_cast119
  %a121 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %t_parent_val122 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %a121, 0
  %t_base_ptr123 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %t_parent_val122, 0
  %t_byte_off124 = mul i64 %iop_tmp120, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8125 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr123, i64 %t_byte_off124
  %t_elem126 = load float, ptr addrspace(1) %t_ptr_i8125, align 4, !invariant.load !1
  %insert_A3 = insertvalue %S_02_hello_mma_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A2, float %t_elem126, 3
  %a-frag = alloca %S_02_hello_mma_REGISTER-FRAGMENT-A-TF32-16X8, align 8
  store %S_02_hello_mma_REGISTER-FRAGMENT-A-TF32-16X8 %insert_A3, ptr %a-frag, align 4
  %subgrouplocalinvocationid127 = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane128 = alloca i32, align 4
  store i32 %subgrouplocalinvocationid127, ptr %lane128, align 4
  %lane129 = load i32, ptr %lane128, align 4
  %iop_tmp130 = sdiv i32 %lane129, 4
  %g131 = alloca i32, align 4
  store i32 %iop_tmp130, ptr %g131, align 4
  %lane132 = load i32, ptr %lane128, align 4
  %mod-x260 = alloca i32, align 4
  store i32 %lane132, ptr %mod-x260, align 4
  %mod-y261 = alloca i32, align 4
  store i32 4, ptr %mod-y261, align 4
  %mod-x260133 = load i32, ptr %mod-x260, align 4
  %mod-x260134 = load i32, ptr %mod-x260, align 4
  %mod-y261135 = load i32, ptr %mod-y261, align 4
  %iop_tmp136 = sdiv i32 %mod-x260134, %mod-y261135
  %mod-y261137 = load i32, ptr %mod-y261, align 4
  %iop_tmp138 = mul i32 %iop_tmp136, %mod-y261137
  %iop_tmp139 = sub i32 %mod-x260133, %iop_tmp138
  %tg140 = alloca i32, align 4
  store i32 %iop_tmp139, ptr %tg140, align 4
  %tg141 = load i32, ptr %tg140, align 4
  %iop_tmp142 = add i32 0, %tg141
  %r143 = alloca i32, align 4
  store i32 %iop_tmp142, ptr %r143, align 4
  %g144 = load i32, ptr %g131, align 4
  %iop_tmp145 = add i32 0, %g144
  %c146 = alloca i32, align 4
  store i32 %iop_tmp145, ptr %c146, align 4
  %r147 = load i32, ptr %r143, align 4
  %sext_cast148 = sext i32 %r147 to i64
  %arr_field_ptr149 = getelementptr inbounds %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, i32 0, i32 3
  %arr_elem_ptr150 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr149, i32 0, i64 1
  %arr_elem151 = load i64, ptr %arr_elem_ptr150, align 4
  %iop_tmp152 = mul i64 %sext_cast148, %arr_elem151
  %c153 = load i32, ptr %c146, align 4
  %sext_cast154 = sext i32 %c153 to i64
  %iop_tmp155 = add i64 %iop_tmp152, %sext_cast154
  %b156 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, align 8
  %t_parent_val157 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %b156, 0
  %t_base_ptr158 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %t_parent_val157, 0
  %t_byte_off159 = mul i64 %iop_tmp155, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8160 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr158, i64 %t_byte_off159
  %t_elem161 = load float, ptr addrspace(1) %t_ptr_i8160, align 4, !invariant.load !1
  %insert_B0 = insertvalue %S_02_hello_mma_REGISTER-FRAGMENT-B-TF32-8X8 undef, float %t_elem161, 0
  %r162 = load i32, ptr %r143, align 4
  %iop_tmp163 = add i32 %r162, 4
  %sext_cast164 = sext i32 %iop_tmp163 to i64
  %arr_field_ptr165 = getelementptr inbounds %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, i32 0, i32 3
  %arr_elem_ptr166 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr165, i32 0, i64 1
  %arr_elem167 = load i64, ptr %arr_elem_ptr166, align 4
  %iop_tmp168 = mul i64 %sext_cast164, %arr_elem167
  %c169 = load i32, ptr %c146, align 4
  %sext_cast170 = sext i32 %c169 to i64
  %iop_tmp171 = add i64 %iop_tmp168, %sext_cast170
  %b172 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST, ptr %b, align 8
  %t_parent_val173 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST %b172, 0
  %t_base_ptr174 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %t_parent_val173, 0
  %t_byte_off175 = mul i64 %iop_tmp171, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8176 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr174, i64 %t_byte_off175
  %t_elem177 = load float, ptr addrspace(1) %t_ptr_i8176, align 4, !invariant.load !1
  %insert_B1 = insertvalue %S_02_hello_mma_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B0, float %t_elem177, 1
  %b-frag = alloca %S_02_hello_mma_REGISTER-FRAGMENT-B-TF32-8X8, align 8
  store %S_02_hello_mma_REGISTER-FRAGMENT-B-TF32-8X8 %insert_B1, ptr %b-frag, align 4
  %c-acc178 = load %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %c-acc, align 4
  %a-frag179 = load %S_02_hello_mma_REGISTER-FRAGMENT-A-TF32-16X8, ptr %a-frag, align 4
  %b-frag180 = load %S_02_hello_mma_REGISTER-FRAGMENT-B-TF32-8X8, ptr %b-frag, align 4
  %a0 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-A-TF32-16X8 %a-frag179, 0
  %a0i = bitcast float %a0 to i32
  %a1 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-A-TF32-16X8 %a-frag179, 1
  %a1i = bitcast float %a1 to i32
  %a2 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-A-TF32-16X8 %a-frag179, 2
  %a2i = bitcast float %a2 to i32
  %a3 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-A-TF32-16X8 %a-frag179, 3
  %a3i = bitcast float %a3 to i32
  %b0 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-B-TF32-8X8 %b-frag180, 0
  %b0i = bitcast float %b0 to i32
  %b1 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-B-TF32-8X8 %b-frag180, 1
  %b1i = bitcast float %b1 to i32
  %c0 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 %c-acc178, 0
  %c1 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 %c-acc178, 1
  %c2 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 %c-acc178, 2
  %c3 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 %c-acc178, 3
  %mma = call { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32 %a0i, i32 %a1i, i32 %a2i, i32 %a3i, i32 %b0i, i32 %b1i, float %c0, float %c1, float %c2, float %c3)
  %d0 = extractvalue { float, float, float, float } %mma, 0
  %acc0 = insertvalue %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 undef, float %d0, 0
  %d1 = extractvalue { float, float, float, float } %mma, 1
  %acc1 = insertvalue %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 %acc0, float %d1, 1
  %d2 = extractvalue { float, float, float, float } %mma, 2
  %acc2 = insertvalue %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 %acc1, float %d2, 2
  %d3 = extractvalue { float, float, float, float } %mma, 3
  %acc3 = insertvalue %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 %acc2, float %d3, 3
  %frag-val = alloca %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8, align 8
  store %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 %acc3, ptr %frag-val, align 4
  %subgrouplocalinvocationid181 = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %lane182 = alloca i32, align 4
  store i32 %subgrouplocalinvocationid181, ptr %lane182, align 4
  %lane183 = load i32, ptr %lane182, align 4
  %iop_tmp184 = sdiv i32 %lane183, 4
  %g185 = alloca i32, align 4
  store i32 %iop_tmp184, ptr %g185, align 4
  %lane186 = load i32, ptr %lane182, align 4
  %mod-x262 = alloca i32, align 4
  store i32 %lane186, ptr %mod-x262, align 4
  %mod-y263 = alloca i32, align 4
  store i32 4, ptr %mod-y263, align 4
  %mod-x262187 = load i32, ptr %mod-x262, align 4
  %mod-x262188 = load i32, ptr %mod-x262, align 4
  %mod-y263189 = load i32, ptr %mod-y263, align 4
  %iop_tmp190 = sdiv i32 %mod-x262188, %mod-y263189
  %mod-y263191 = load i32, ptr %mod-y263, align 4
  %iop_tmp192 = mul i32 %iop_tmp190, %mod-y263191
  %iop_tmp193 = sub i32 %mod-x262187, %iop_tmp192
  %iop_tmp194 = mul i32 2, %iop_tmp193
  %t2 = alloca i32, align 4
  store i32 %iop_tmp194, ptr %t2, align 4
  %g195 = load i32, ptr %g185, align 4
  %iop_tmp196 = add i32 0, %g195
  %row = alloca i32, align 4
  store i32 %iop_tmp196, ptr %row, align 4
  %t2197 = load i32, ptr %t2, align 4
  %iop_tmp198 = add i32 0, %t2197
  %col = alloca i32, align 4
  store i32 %iop_tmp198, ptr %col, align 4
  %frag-val199 = load %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_0 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val199, 0
  %row200 = load i32, ptr %row, align 4
  %sext_cast201 = sext i32 %row200 to i64
  %arr_field_ptr202 = getelementptr inbounds %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr203 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr202, i32 0, i64 1
  %arr_elem204 = load i64, ptr %arr_elem_ptr203, align 4
  %iop_tmp205 = mul i64 %sext_cast201, %arr_elem204
  %col206 = load i32, ptr %col, align 4
  %sext_cast207 = sext i32 %col206 to i64
  %iop_tmp208 = add i64 %iop_tmp205, %sext_cast207
  %c209 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val210 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c209, 0
  %t_base_ptr211 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %t_parent_val210, 0
  %t_byte_off212 = mul i64 %iop_tmp208, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8213 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr211, i64 %t_byte_off212
  %t_elem214 = load float, ptr addrspace(1) %t_ptr_i8213, align 4
  store float %extract_0, ptr addrspace(1) %t_ptr_i8213, align 4
  %frag-val215 = load %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_1 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val215, 1
  %row216 = load i32, ptr %row, align 4
  %sext_cast217 = sext i32 %row216 to i64
  %arr_field_ptr218 = getelementptr inbounds %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr219 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr218, i32 0, i64 1
  %arr_elem220 = load i64, ptr %arr_elem_ptr219, align 4
  %iop_tmp221 = mul i64 %sext_cast217, %arr_elem220
  %col222 = load i32, ptr %col, align 4
  %iop_tmp223 = add i32 %col222, 1
  %sext_cast224 = sext i32 %iop_tmp223 to i64
  %iop_tmp225 = add i64 %iop_tmp221, %sext_cast224
  %c226 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val227 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c226, 0
  %t_base_ptr228 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %t_parent_val227, 0
  %t_byte_off229 = mul i64 %iop_tmp225, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8230 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr228, i64 %t_byte_off229
  %t_elem231 = load float, ptr addrspace(1) %t_ptr_i8230, align 4
  store float %extract_1, ptr addrspace(1) %t_ptr_i8230, align 4
  %frag-val232 = load %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_2 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val232, 2
  %row233 = load i32, ptr %row, align 4
  %iop_tmp234 = add i32 %row233, 8
  %sext_cast235 = sext i32 %iop_tmp234 to i64
  %arr_field_ptr236 = getelementptr inbounds %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr237 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr236, i32 0, i64 1
  %arr_elem238 = load i64, ptr %arr_elem_ptr237, align 4
  %iop_tmp239 = mul i64 %sext_cast235, %arr_elem238
  %col240 = load i32, ptr %col, align 4
  %sext_cast241 = sext i32 %col240 to i64
  %iop_tmp242 = add i64 %iop_tmp239, %sext_cast241
  %c243 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val244 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c243, 0
  %t_base_ptr245 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %t_parent_val244, 0
  %t_byte_off246 = mul i64 %iop_tmp242, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8247 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr245, i64 %t_byte_off246
  %t_elem248 = load float, ptr addrspace(1) %t_ptr_i8247, align 4
  store float %extract_2, ptr addrspace(1) %t_ptr_i8247, align 4
  %frag-val249 = load %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8, ptr %frag-val, align 4
  %extract_3 = extractvalue %S_02_hello_mma_REGISTER-FRAGMENT-ACC-F32-16X8 %frag-val249, 3
  %row250 = load i32, ptr %row, align 4
  %iop_tmp251 = add i32 %row250, 8
  %sext_cast252 = sext i32 %iop_tmp251 to i64
  %arr_field_ptr253 = getelementptr inbounds %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, i32 0, i32 3
  %arr_elem_ptr254 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr253, i32 0, i64 1
  %arr_elem255 = load i64, ptr %arr_elem_ptr254, align 4
  %iop_tmp256 = mul i64 %sext_cast252, %arr_elem255
  %col257 = load i32, ptr %col, align 4
  %iop_tmp258 = add i32 %col257, 1
  %sext_cast259 = sext i32 %iop_tmp258 to i64
  %iop_tmp260 = add i64 %iop_tmp256, %sext_cast259
  %c261 = load %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val262 = extractvalue %S_02_hello_mma_TENSOR_FLOAT_2_GLOBAL_COMPACT_LAST %c261, 0
  %t_base_ptr263 = extractvalue %S_02_hello_mma_STORAGE_GLOBAL %t_parent_val262, 0
  %t_byte_off264 = mul i64 %iop_tmp260, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8265 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr263, i64 %t_byte_off264
  %t_elem266 = load float, ptr addrspace(1) %t_ptr_i8265, align 4
  store float %extract_3, ptr addrspace(1) %t_ptr_i8265, align 4
  ret void
}

; Function Attrs: nocallback nounwind memory(none)
declare { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32, i32, i32, i32, i32, i32, float, float, float, float) #1

attributes #0 = { "denormal-fp-math"="ieee,ieee" "denormal-fp-math-f32"="ieee,ieee" }
attributes #1 = { nocallback nounwind memory(none) }

!spirv.ExecutionMode = !{!0}

!0 = !{ptr @hello_mma, i32 4459, i32 32}
!1 = !{}


!100 = !{i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0}
!101 = !{!"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none"}
!102 = !{!"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong"}
!103 = !{!"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong"}
!104 = !{!"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !""}
