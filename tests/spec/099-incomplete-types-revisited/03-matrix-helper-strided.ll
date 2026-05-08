; ModuleID = '03-matrix-helper-strided'
source_filename = "03-matrix-helper-strided"

%STORAGE_GLOBAL = type { ptr addrspace(1), i64 }
%TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST = type { %STORAGE_GLOBAL, [2 x i64], [2 x i64], [2 x i64], i64 }

define ptr addrspace(1) @address__storage_global(ptr addrspace(1) %0, i64 %1) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %STORAGE_GLOBAL, align 8
  store %STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %STORAGE_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %STORAGE_GLOBAL %obj1, 0
  ret ptr addrspace(1) %extract_0
}

define i64 @byte_size__storage_global(ptr addrspace(1) %0, i64 %1) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %STORAGE_GLOBAL, align 8
  store %STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %STORAGE_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %STORAGE_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define i32 @address_space__storage_global(ptr addrspace(1) %0, i64 %1) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %STORAGE_GLOBAL, align 8
  store %STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  ret i32 1
}

define ptr addrspace(1) @_address__storage_global(ptr addrspace(1) %0, i64 %1) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %STORAGE_GLOBAL, align 8
  store %STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %STORAGE_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %STORAGE_GLOBAL %obj1, 0
  ret ptr addrspace(1) %extract_0
}

define i64 @_byte_size__storage_global(ptr addrspace(1) %0, i64 %1) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %obj = alloca %STORAGE_GLOBAL, align 8
  store %STORAGE_GLOBAL %BYTE-SIZE_ins, ptr %obj, align 8
  %obj1 = load %STORAGE_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %STORAGE_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define %STORAGE_GLOBAL @parent__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %obj5, 0
  ret %STORAGE_GLOBAL %extract_0
}

define [2 x i64] @offset__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_1 = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %obj5, 1
  ret [2 x i64] %extract_1
}

define [2 x i64] @strides__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_2 = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %obj5, 2
  ret [2 x i64] %extract_2
}

define [2 x i64] @extents__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_3 = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %obj5, 3
  ret [2 x i64] %extract_3
}

define i64 @length__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %obj5, 4
  ret i64 %extract_4
}

define i64 @num_dims__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  ret i64 2
}

define i32 @address_space__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define i32 @align__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 2
}

define i32 @contiguous_term__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define %STORAGE_GLOBAL @_parent__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %obj5, 0
  ret %STORAGE_GLOBAL %extract_0
}

define [2 x i64] @_offset__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_1 = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %obj5, 1
  ret [2 x i64] %extract_1
}

define [2 x i64] @_strides__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_2 = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %obj5, 2
  ret [2 x i64] %extract_2
}

define [2 x i64] @_extents__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_3 = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %obj5, 3
  ret [2 x i64] %extract_3
}

define i64 @_length__tensor_float_2_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %obj = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj5 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %obj5, 4
  ret i64 %extract_4
}

define float @read_at_2d_tensor_float_2_global_strided_last_ulong_ulong(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8, i64 %9, i64 %10) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [2 x i64] undef, i64 %2, 0
  %arr_build_1 = insertvalue [2 x i64] %arr_build_0, i64 %3, 1
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %PARENT_ins, [2 x i64] %arr_build_1, 1
  %arr_build_01 = insertvalue [2 x i64] undef, i64 %4, 0
  %arr_build_12 = insertvalue [2 x i64] %arr_build_01, i64 %5, 1
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %OFFSET_ins, [2 x i64] %arr_build_12, 2
  %arr_build_03 = insertvalue [2 x i64] undef, i64 %6, 0
  %arr_build_14 = insertvalue [2 x i64] %arr_build_03, i64 %7, 1
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %STRIDES_ins, [2 x i64] %arr_build_14, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %8, 4
  %m = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %m, align 8
  %i = alloca i64, align 8
  store i64 %9, ptr %i, align 4
  %j = alloca i64, align 8
  store i64 %10, ptr %j, align 4
  %arr_field_ptr = getelementptr inbounds %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %m, i32 0, i32 1
  %arr_elem_ptr = getelementptr inbounds [2 x i64], ptr %arr_field_ptr, i32 0, i64 0
  %arr_elem = load i64, ptr %arr_elem_ptr, align 4
  %i5 = load i64, ptr %i, align 4
  %arr_field_ptr6 = getelementptr inbounds %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %m, i32 0, i32 2
  %arr_elem_ptr7 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr6, i32 0, i64 0
  %arr_elem8 = load i64, ptr %arr_elem_ptr7, align 4
  %iop_tmp = mul i64 %i5, %arr_elem8
  %iop_tmp9 = add i64 %arr_elem, %iop_tmp
  %arr_field_ptr10 = getelementptr inbounds %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %m, i32 0, i32 1
  %arr_elem_ptr11 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr10, i32 0, i64 1
  %arr_elem12 = load i64, ptr %arr_elem_ptr11, align 4
  %j13 = load i64, ptr %j, align 4
  %arr_field_ptr14 = getelementptr inbounds %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %m, i32 0, i32 2
  %arr_elem_ptr15 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr14, i32 0, i64 1
  %arr_elem16 = load i64, ptr %arr_elem_ptr15, align 4
  %iop_tmp17 = mul i64 %j13, %arr_elem16
  %iop_tmp18 = add i64 %arr_elem12, %iop_tmp17
  %iop_tmp19 = add i64 %iop_tmp9, %iop_tmp18
  %m20 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %m, align 8
  %t_parent_val = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %m20, 0
  %t_base_ptr = extractvalue %STORAGE_GLOBAL %t_parent_val, 0
  %t_byte_off = mul i64 %iop_tmp19, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr, i64 %t_byte_off
  %t_elem = load float, ptr addrspace(1) %t_ptr_i8, align 4
  ret float %t_elem
}

define void @matrix_helper_test(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8, i64 %9, i64 %10, ptr addrspace(1) %11, i64 %12, i64 %13, i64 %14, i64 %15, i64 %16, i64 %17, i64 %18, i64 %19) {
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
  %i = alloca i64, align 8
  store i64 %9, ptr %i, align 4
  %j = alloca i64, align 8
  store i64 %10, ptr %j, align 4
  %c_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %11, ptr %c_ptr, align 8
  %c_byte_size = alloca i64, align 8
  store i64 %12, ptr %c_byte_size, align 4
  %c_offset_0 = alloca i64, align 8
  store i64 %13, ptr %c_offset_0, align 4
  %c_offset_1 = alloca i64, align 8
  store i64 %14, ptr %c_offset_1, align 4
  %c_stride_0 = alloca i64, align 8
  store i64 %15, ptr %c_stride_0, align 4
  %c_stride_1 = alloca i64, align 8
  store i64 %16, ptr %c_stride_1, align 4
  %c_extent_0 = alloca i64, align 8
  store i64 %17, ptr %c_extent_0, align 4
  %c_extent_1 = alloca i64, align 8
  store i64 %18, ptr %c_extent_1, align 4
  %c_length = alloca i64, align 8
  store i64 %19, ptr %c_length, align 4
  %a_ptr1 = load ptr addrspace(1), ptr %a_ptr, align 8
  %insert_ADDRESS = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %a_ptr1, 0
  %a_byte_size2 = load i64, ptr %a_byte_size, align 4
  %insert_BYTE-SIZE = insertvalue %STORAGE_GLOBAL %insert_ADDRESS, i64 %a_byte_size2, 1
  %insert_PARENT = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %insert_BYTE-SIZE, 0
  %a_offset_03 = load i64, ptr %a_offset_0, align 4
  %arr_ins_0 = insertvalue [2 x i64] undef, i64 %a_offset_03, 0
  %a_offset_14 = load i64, ptr %a_offset_1, align 4
  %arr_ins_1 = insertvalue [2 x i64] %arr_ins_0, i64 %a_offset_14, 1
  %insert_OFFSET = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %insert_PARENT, [2 x i64] %arr_ins_1, 1
  %a_stride_05 = load i64, ptr %a_stride_0, align 4
  %arr_ins_06 = insertvalue [2 x i64] undef, i64 %a_stride_05, 0
  %a_stride_17 = load i64, ptr %a_stride_1, align 4
  %arr_ins_18 = insertvalue [2 x i64] %arr_ins_06, i64 %a_stride_17, 1
  %insert_STRIDES = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %insert_OFFSET, [2 x i64] %arr_ins_18, 2
  %a_extent_09 = load i64, ptr %a_extent_0, align 4
  %arr_ins_010 = insertvalue [2 x i64] undef, i64 %a_extent_09, 0
  %a_extent_111 = load i64, ptr %a_extent_1, align 4
  %arr_ins_112 = insertvalue [2 x i64] %arr_ins_010, i64 %a_extent_111, 1
  %insert_EXTENTS = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %insert_STRIDES, [2 x i64] %arr_ins_112, 3
  %a_length13 = load i64, ptr %a_length, align 4
  %insert_LENGTH = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %insert_EXTENTS, i64 %a_length13, 4
  %a = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %insert_LENGTH, ptr %a, align 8
  %c_ptr14 = load ptr addrspace(1), ptr %c_ptr, align 8
  %insert_ADDRESS15 = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %c_ptr14, 0
  %c_byte_size16 = load i64, ptr %c_byte_size, align 4
  %insert_BYTE-SIZE17 = insertvalue %STORAGE_GLOBAL %insert_ADDRESS15, i64 %c_byte_size16, 1
  %insert_PARENT18 = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %insert_BYTE-SIZE17, 0
  %c_offset_019 = load i64, ptr %c_offset_0, align 4
  %arr_ins_020 = insertvalue [2 x i64] undef, i64 %c_offset_019, 0
  %c_offset_121 = load i64, ptr %c_offset_1, align 4
  %arr_ins_122 = insertvalue [2 x i64] %arr_ins_020, i64 %c_offset_121, 1
  %insert_OFFSET23 = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %insert_PARENT18, [2 x i64] %arr_ins_122, 1
  %c_stride_024 = load i64, ptr %c_stride_0, align 4
  %arr_ins_025 = insertvalue [2 x i64] undef, i64 %c_stride_024, 0
  %c_stride_126 = load i64, ptr %c_stride_1, align 4
  %arr_ins_127 = insertvalue [2 x i64] %arr_ins_025, i64 %c_stride_126, 1
  %insert_STRIDES28 = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %insert_OFFSET23, [2 x i64] %arr_ins_127, 2
  %c_extent_029 = load i64, ptr %c_extent_0, align 4
  %arr_ins_030 = insertvalue [2 x i64] undef, i64 %c_extent_029, 0
  %c_extent_131 = load i64, ptr %c_extent_1, align 4
  %arr_ins_132 = insertvalue [2 x i64] %arr_ins_030, i64 %c_extent_131, 1
  %insert_EXTENTS33 = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %insert_STRIDES28, [2 x i64] %arr_ins_132, 3
  %c_length34 = load i64, ptr %c_length, align 4
  %insert_LENGTH35 = insertvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %insert_EXTENTS33, i64 %c_length34, 4
  %c = alloca %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %insert_LENGTH35, ptr %c, align 8
  %a36 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %a, align 8
  %PARENT_val = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %a36, 0
  %ADDRESS_val = extractvalue %STORAGE_GLOBAL %PARENT_val, 0
  %BYTE-SIZE_val = extractvalue %STORAGE_GLOBAL %PARENT_val, 1
  %OFFSET_val = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %a36, 1
  %arr_elem_0 = extractvalue [2 x i64] %OFFSET_val, 0
  %arr_elem_1 = extractvalue [2 x i64] %OFFSET_val, 1
  %STRIDES_val = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %a36, 2
  %arr_elem_037 = extractvalue [2 x i64] %STRIDES_val, 0
  %arr_elem_138 = extractvalue [2 x i64] %STRIDES_val, 1
  %EXTENTS_val = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %a36, 3
  %arr_elem_039 = extractvalue [2 x i64] %EXTENTS_val, 0
  %arr_elem_140 = extractvalue [2 x i64] %EXTENTS_val, 1
  %LENGTH_val = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %a36, 4
  %i41 = load i64, ptr %i, align 4
  %j42 = load i64, ptr %j, align 4
  %call_tmp = call float @read_at_2d_tensor_float_2_global_strided_last_ulong_ulong(ptr addrspace(1) %ADDRESS_val, i64 %BYTE-SIZE_val, i64 %arr_elem_0, i64 %arr_elem_1, i64 %arr_elem_037, i64 %arr_elem_138, i64 %arr_elem_039, i64 %arr_elem_140, i64 %LENGTH_val, i64 %i41, i64 %j42)
  %arr_field_ptr = getelementptr inbounds %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %c, i32 0, i32 1
  %arr_elem_ptr = getelementptr inbounds [2 x i64], ptr %arr_field_ptr, i32 0, i64 0
  %arr_elem = load i64, ptr %arr_elem_ptr, align 4
  %i43 = load i64, ptr %i, align 4
  %arr_field_ptr44 = getelementptr inbounds %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %c, i32 0, i32 2
  %arr_elem_ptr45 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr44, i32 0, i64 0
  %arr_elem46 = load i64, ptr %arr_elem_ptr45, align 4
  %iop_tmp = mul i64 %i43, %arr_elem46
  %iop_tmp47 = add i64 %arr_elem, %iop_tmp
  %arr_field_ptr48 = getelementptr inbounds %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %c, i32 0, i32 1
  %arr_elem_ptr49 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr48, i32 0, i64 1
  %arr_elem50 = load i64, ptr %arr_elem_ptr49, align 4
  %j51 = load i64, ptr %j, align 4
  %arr_field_ptr52 = getelementptr inbounds %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %c, i32 0, i32 2
  %arr_elem_ptr53 = getelementptr inbounds [2 x i64], ptr %arr_field_ptr52, i32 0, i64 1
  %arr_elem54 = load i64, ptr %arr_elem_ptr53, align 4
  %iop_tmp55 = mul i64 %j51, %arr_elem54
  %iop_tmp56 = add i64 %arr_elem50, %iop_tmp55
  %iop_tmp57 = add i64 %iop_tmp47, %iop_tmp56
  %c58 = load %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST, ptr %c, align 8
  %t_parent_val = extractvalue %TENSOR_FLOAT_2_GLOBAL_STRIDED_LAST %c58, 0
  %t_base_ptr = extractvalue %STORAGE_GLOBAL %t_parent_val, 0
  %t_byte_off = mul i64 %iop_tmp57, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr, i64 %t_byte_off
  %t_elem = load float, ptr addrspace(1) %t_ptr_i8, align 4
  store float %call_tmp, ptr addrspace(1) %t_ptr_i8, align 4
  ret void
}
