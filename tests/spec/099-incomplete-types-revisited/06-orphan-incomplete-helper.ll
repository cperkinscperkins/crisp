; ModuleID = '06-orphan-incomplete-helper'
source_filename = "06-orphan-incomplete-helper"

%STORAGE_GLOBAL = type { ptr addrspace(1), i64 }
%TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST = type { %STORAGE_GLOBAL, [1 x i64], [1 x i64], [1 x i64], i64 }

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

define %STORAGE_GLOBAL @parent__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %obj3, 0
  ret %STORAGE_GLOBAL %extract_0
}

define [1 x i64] @offset__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_1 = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %obj3, 1
  ret [1 x i64] %extract_1
}

define [1 x i64] @strides__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_2 = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %obj3, 2
  ret [1 x i64] %extract_2
}

define [1 x i64] @extents__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_3 = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %obj3, 3
  ret [1 x i64] %extract_3
}

define i64 @length__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %obj3, 4
  ret i64 %extract_4
}

define i64 @num_dims__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i64 1
}

define i32 @address_space__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define i32 @align__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define i32 @contiguous_term__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define %STORAGE_GLOBAL @_parent__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %obj3, 0
  ret %STORAGE_GLOBAL %extract_0
}

define [1 x i64] @_offset__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_1 = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %obj3, 1
  ret [1 x i64] %extract_1
}

define [1 x i64] @_strides__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_2 = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %obj3, 2
  ret [1 x i64] %extract_2
}

define [1 x i64] @_extents__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_3 = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %obj3, 3
  ret [1 x i64] %extract_3
}

define i64 @_length__tensor_float_1_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %obj3, 4
  ret i64 %extract_4
}

define void @trivial_kernel(i64 %0, ptr addrspace(1) %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6) {
entry:
  %idx = alloca i64, align 8
  store i64 %0, ptr %idx, align 4
  %c_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %1, ptr %c_ptr, align 8
  %c_byte_size = alloca i64, align 8
  store i64 %2, ptr %c_byte_size, align 4
  %c_offset_0 = alloca i64, align 8
  store i64 %3, ptr %c_offset_0, align 4
  %c_stride_0 = alloca i64, align 8
  store i64 %4, ptr %c_stride_0, align 4
  %c_extent_0 = alloca i64, align 8
  store i64 %5, ptr %c_extent_0, align 4
  %c_length = alloca i64, align 8
  store i64 %6, ptr %c_length, align 4
  %c_ptr1 = load ptr addrspace(1), ptr %c_ptr, align 8
  %insert_ADDRESS = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %c_ptr1, 0
  %c_byte_size2 = load i64, ptr %c_byte_size, align 4
  %insert_BYTE-SIZE = insertvalue %STORAGE_GLOBAL %insert_ADDRESS, i64 %c_byte_size2, 1
  %insert_PARENT = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %insert_BYTE-SIZE, 0
  %c_offset_03 = load i64, ptr %c_offset_0, align 4
  %arr_ins_0 = insertvalue [1 x i64] undef, i64 %c_offset_03, 0
  %insert_OFFSET = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_PARENT, [1 x i64] %arr_ins_0, 1
  %c_stride_04 = load i64, ptr %c_stride_0, align 4
  %arr_ins_05 = insertvalue [1 x i64] undef, i64 %c_stride_04, 0
  %insert_STRIDES = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_OFFSET, [1 x i64] %arr_ins_05, 2
  %c_extent_06 = load i64, ptr %c_extent_0, align 4
  %arr_ins_07 = insertvalue [1 x i64] undef, i64 %c_extent_06, 0
  %insert_EXTENTS = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_STRIDES, [1 x i64] %arr_ins_07, 3
  %c_length8 = load i64, ptr %c_length, align 4
  %insert_LENGTH = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_EXTENTS, i64 %c_length8, 4
  %c = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_LENGTH, ptr %c, align 8
  %idx9 = load i64, ptr %idx, align 4
  %c10 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %c10, 0
  %t_base_ptr = extractvalue %STORAGE_GLOBAL %t_parent_val, 0
  %t_byte_off = mul i64 %idx9, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr, i64 %t_byte_off
  %t_elem = load float, ptr addrspace(1) %t_ptr_i8, align 4
  store float 0.000000e+00, ptr addrspace(1) %t_ptr_i8, align 4
  ret void
}
