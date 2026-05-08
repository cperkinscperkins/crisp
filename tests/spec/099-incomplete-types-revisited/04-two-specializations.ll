; ModuleID = '04-two-specializations'
source_filename = "04-two-specializations"

%STORAGE_GLOBAL = type { ptr addrspace(1), i64 }
%TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST = type { %STORAGE_GLOBAL, [1 x i64], [1 x i64], [1 x i64], i64 }
%TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST = type { %STORAGE_GLOBAL, [1 x i64], [1 x i64], [1 x i64], i64 }

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

define %STORAGE_GLOBAL @parent__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %obj3, 0
  ret %STORAGE_GLOBAL %extract_0
}

define [1 x i64] @offset__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_1 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %obj3, 1
  ret [1 x i64] %extract_1
}

define [1 x i64] @strides__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_2 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %obj3, 2
  ret [1 x i64] %extract_2
}

define [1 x i64] @extents__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_3 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %obj3, 3
  ret [1 x i64] %extract_3
}

define i64 @length__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %obj3, 4
  ret i64 %extract_4
}

define i64 @num_dims__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  ret i64 1
}

define i32 @address_space__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 1
}

define i32 @align__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 2
}

define i32 @contiguous_term__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  ret i32 0
}

define %STORAGE_GLOBAL @_parent__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_0 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %obj3, 0
  ret %STORAGE_GLOBAL %extract_0
}

define [1 x i64] @_offset__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_1 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %obj3, 1
  ret [1 x i64] %extract_1
}

define [1 x i64] @_strides__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_2 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %obj3, 2
  ret [1 x i64] %extract_2
}

define [1 x i64] @_extents__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_3 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %obj3, 3
  ret [1 x i64] %extract_3
}

define i64 @_length__tensor_float_1_global_strided_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %obj = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %obj, align 8
  %obj3 = load %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %obj, align 8
  %extract_4 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %obj3, 4
  ret i64 %extract_4
}

define float @double_at_tensor_float_1_global_compact_last_ulong(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6) {
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
  %v = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %LENGTH_ins, ptr %v, align 8
  %idx = alloca i64, align 8
  store i64 %6, ptr %idx, align 4
  %idx3 = load i64, ptr %idx, align 4
  %v4 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %v, align 8
  %t_parent_val = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %v4, 0
  %t_base_ptr = extractvalue %STORAGE_GLOBAL %t_parent_val, 0
  %t_byte_off = mul i64 %idx3, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr, i64 %t_byte_off
  %t_elem = load float, ptr addrspace(1) %t_ptr_i8, align 4
  %fop_tmp = fmul float %t_elem, 2.000000e+00
  ret float %fop_tmp
}

define float @double_at_tensor_float_1_global_strided_last_ulong(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %arr_build_0 = insertvalue [1 x i64] undef, i64 %2, 0
  %OFFSET_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %PARENT_ins, [1 x i64] %arr_build_0, 1
  %arr_build_01 = insertvalue [1 x i64] undef, i64 %3, 0
  %STRIDES_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %OFFSET_ins, [1 x i64] %arr_build_01, 2
  %arr_build_02 = insertvalue [1 x i64] undef, i64 %4, 0
  %EXTENTS_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %STRIDES_ins, [1 x i64] %arr_build_02, 3
  %LENGTH_ins = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %EXTENTS_ins, i64 %5, 4
  %v = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %LENGTH_ins, ptr %v, align 8
  %idx = alloca i64, align 8
  store i64 %6, ptr %idx, align 4
  %arr_field_ptr = getelementptr inbounds %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %v, i32 0, i32 1
  %arr_elem_ptr = getelementptr inbounds [1 x i64], ptr %arr_field_ptr, i32 0, i64 0
  %arr_elem = load i64, ptr %arr_elem_ptr, align 4
  %idx3 = load i64, ptr %idx, align 4
  %arr_field_ptr4 = getelementptr inbounds %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %v, i32 0, i32 2
  %arr_elem_ptr5 = getelementptr inbounds [1 x i64], ptr %arr_field_ptr4, i32 0, i64 0
  %arr_elem6 = load i64, ptr %arr_elem_ptr5, align 4
  %iop_tmp = mul i64 %idx3, %arr_elem6
  %iop_tmp7 = add i64 %arr_elem, %iop_tmp
  %v8 = load %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %v, align 8
  %t_parent_val = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %v8, 0
  %t_base_ptr = extractvalue %STORAGE_GLOBAL %t_parent_val, 0
  %t_byte_off = mul i64 %iop_tmp7, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr, i64 %t_byte_off
  %t_elem = load float, ptr addrspace(1) %t_ptr_i8, align 4
  %fop_tmp = fmul float %t_elem, 2.000000e+00
  ret float %fop_tmp
}

define void @two_specs_test(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, ptr addrspace(1) %6, i64 %7, i64 %8, i64 %9, i64 %10, i64 %11, i64 %12, ptr addrspace(1) %13, i64 %14, i64 %15, i64 %16, i64 %17, i64 %18) {
entry:
  %a_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %0, ptr %a_ptr, align 8
  %a_byte_size = alloca i64, align 8
  store i64 %1, ptr %a_byte_size, align 4
  %a_offset_0 = alloca i64, align 8
  store i64 %2, ptr %a_offset_0, align 4
  %a_stride_0 = alloca i64, align 8
  store i64 %3, ptr %a_stride_0, align 4
  %a_extent_0 = alloca i64, align 8
  store i64 %4, ptr %a_extent_0, align 4
  %a_length = alloca i64, align 8
  store i64 %5, ptr %a_length, align 4
  %b_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %6, ptr %b_ptr, align 8
  %b_byte_size = alloca i64, align 8
  store i64 %7, ptr %b_byte_size, align 4
  %b_offset_0 = alloca i64, align 8
  store i64 %8, ptr %b_offset_0, align 4
  %b_stride_0 = alloca i64, align 8
  store i64 %9, ptr %b_stride_0, align 4
  %b_extent_0 = alloca i64, align 8
  store i64 %10, ptr %b_extent_0, align 4
  %b_length = alloca i64, align 8
  store i64 %11, ptr %b_length, align 4
  %idx = alloca i64, align 8
  store i64 %12, ptr %idx, align 4
  %c_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %13, ptr %c_ptr, align 8
  %c_byte_size = alloca i64, align 8
  store i64 %14, ptr %c_byte_size, align 4
  %c_offset_0 = alloca i64, align 8
  store i64 %15, ptr %c_offset_0, align 4
  %c_stride_0 = alloca i64, align 8
  store i64 %16, ptr %c_stride_0, align 4
  %c_extent_0 = alloca i64, align 8
  store i64 %17, ptr %c_extent_0, align 4
  %c_length = alloca i64, align 8
  store i64 %18, ptr %c_length, align 4
  %a_ptr1 = load ptr addrspace(1), ptr %a_ptr, align 8
  %insert_ADDRESS = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %a_ptr1, 0
  %a_byte_size2 = load i64, ptr %a_byte_size, align 4
  %insert_BYTE-SIZE = insertvalue %STORAGE_GLOBAL %insert_ADDRESS, i64 %a_byte_size2, 1
  %insert_PARENT = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %insert_BYTE-SIZE, 0
  %a_offset_03 = load i64, ptr %a_offset_0, align 4
  %arr_ins_0 = insertvalue [1 x i64] undef, i64 %a_offset_03, 0
  %insert_OFFSET = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_PARENT, [1 x i64] %arr_ins_0, 1
  %a_stride_04 = load i64, ptr %a_stride_0, align 4
  %arr_ins_05 = insertvalue [1 x i64] undef, i64 %a_stride_04, 0
  %insert_STRIDES = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_OFFSET, [1 x i64] %arr_ins_05, 2
  %a_extent_06 = load i64, ptr %a_extent_0, align 4
  %arr_ins_07 = insertvalue [1 x i64] undef, i64 %a_extent_06, 0
  %insert_EXTENTS = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_STRIDES, [1 x i64] %arr_ins_07, 3
  %a_length8 = load i64, ptr %a_length, align 4
  %insert_LENGTH = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_EXTENTS, i64 %a_length8, 4
  %a = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_LENGTH, ptr %a, align 8
  %b_ptr9 = load ptr addrspace(1), ptr %b_ptr, align 8
  %insert_ADDRESS10 = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %b_ptr9, 0
  %b_byte_size11 = load i64, ptr %b_byte_size, align 4
  %insert_BYTE-SIZE12 = insertvalue %STORAGE_GLOBAL %insert_ADDRESS10, i64 %b_byte_size11, 1
  %insert_PARENT13 = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST undef, %STORAGE_GLOBAL %insert_BYTE-SIZE12, 0
  %b_offset_014 = load i64, ptr %b_offset_0, align 4
  %arr_ins_015 = insertvalue [1 x i64] undef, i64 %b_offset_014, 0
  %insert_OFFSET16 = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %insert_PARENT13, [1 x i64] %arr_ins_015, 1
  %b_stride_017 = load i64, ptr %b_stride_0, align 4
  %arr_ins_018 = insertvalue [1 x i64] undef, i64 %b_stride_017, 0
  %insert_STRIDES19 = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %insert_OFFSET16, [1 x i64] %arr_ins_018, 2
  %b_extent_020 = load i64, ptr %b_extent_0, align 4
  %arr_ins_021 = insertvalue [1 x i64] undef, i64 %b_extent_020, 0
  %insert_EXTENTS22 = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %insert_STRIDES19, [1 x i64] %arr_ins_021, 3
  %b_length23 = load i64, ptr %b_length, align 4
  %insert_LENGTH24 = insertvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %insert_EXTENTS22, i64 %b_length23, 4
  %b = alloca %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %insert_LENGTH24, ptr %b, align 8
  %c_ptr25 = load ptr addrspace(1), ptr %c_ptr, align 8
  %insert_ADDRESS26 = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %c_ptr25, 0
  %c_byte_size27 = load i64, ptr %c_byte_size, align 4
  %insert_BYTE-SIZE28 = insertvalue %STORAGE_GLOBAL %insert_ADDRESS26, i64 %c_byte_size27, 1
  %insert_PARENT29 = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST undef, %STORAGE_GLOBAL %insert_BYTE-SIZE28, 0
  %c_offset_030 = load i64, ptr %c_offset_0, align 4
  %arr_ins_031 = insertvalue [1 x i64] undef, i64 %c_offset_030, 0
  %insert_OFFSET32 = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_PARENT29, [1 x i64] %arr_ins_031, 1
  %c_stride_033 = load i64, ptr %c_stride_0, align 4
  %arr_ins_034 = insertvalue [1 x i64] undef, i64 %c_stride_033, 0
  %insert_STRIDES35 = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_OFFSET32, [1 x i64] %arr_ins_034, 2
  %c_extent_036 = load i64, ptr %c_extent_0, align 4
  %arr_ins_037 = insertvalue [1 x i64] undef, i64 %c_extent_036, 0
  %insert_EXTENTS38 = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_STRIDES35, [1 x i64] %arr_ins_037, 3
  %c_length39 = load i64, ptr %c_length, align 4
  %insert_LENGTH40 = insertvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_EXTENTS38, i64 %c_length39, 4
  %c = alloca %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, align 8
  store %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %insert_LENGTH40, ptr %c, align 8
  %a41 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %a, align 8
  %PARENT_val = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %a41, 0
  %ADDRESS_val = extractvalue %STORAGE_GLOBAL %PARENT_val, 0
  %BYTE-SIZE_val = extractvalue %STORAGE_GLOBAL %PARENT_val, 1
  %OFFSET_val = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %a41, 1
  %arr_elem_0 = extractvalue [1 x i64] %OFFSET_val, 0
  %STRIDES_val = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %a41, 2
  %arr_elem_042 = extractvalue [1 x i64] %STRIDES_val, 0
  %EXTENTS_val = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %a41, 3
  %arr_elem_043 = extractvalue [1 x i64] %EXTENTS_val, 0
  %LENGTH_val = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %a41, 4
  %idx44 = load i64, ptr %idx, align 4
  %call_tmp = call float @double_at_tensor_float_1_global_compact_last_ulong(ptr addrspace(1) %ADDRESS_val, i64 %BYTE-SIZE_val, i64 %arr_elem_0, i64 %arr_elem_042, i64 %arr_elem_043, i64 %LENGTH_val, i64 %idx44)
  %b45 = load %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST, ptr %b, align 8
  %PARENT_val46 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %b45, 0
  %ADDRESS_val47 = extractvalue %STORAGE_GLOBAL %PARENT_val46, 0
  %BYTE-SIZE_val48 = extractvalue %STORAGE_GLOBAL %PARENT_val46, 1
  %OFFSET_val49 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %b45, 1
  %arr_elem_050 = extractvalue [1 x i64] %OFFSET_val49, 0
  %STRIDES_val51 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %b45, 2
  %arr_elem_052 = extractvalue [1 x i64] %STRIDES_val51, 0
  %EXTENTS_val53 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %b45, 3
  %arr_elem_054 = extractvalue [1 x i64] %EXTENTS_val53, 0
  %LENGTH_val55 = extractvalue %TENSOR_FLOAT_1_GLOBAL_STRIDED_LAST %b45, 4
  %idx56 = load i64, ptr %idx, align 4
  %call_tmp57 = call float @double_at_tensor_float_1_global_strided_last_ulong(ptr addrspace(1) %ADDRESS_val47, i64 %BYTE-SIZE_val48, i64 %arr_elem_050, i64 %arr_elem_052, i64 %arr_elem_054, i64 %LENGTH_val55, i64 %idx56)
  %fop_tmp = fadd float %call_tmp, %call_tmp57
  %idx58 = load i64, ptr %idx, align 4
  %c59 = load %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST, ptr %c, align 8
  %t_parent_val = extractvalue %TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST %c59, 0
  %t_base_ptr = extractvalue %STORAGE_GLOBAL %t_parent_val, 0
  %t_byte_off = mul i64 %idx58, ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)
  %t_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %t_base_ptr, i64 %t_byte_off
  %t_elem = load float, ptr addrspace(1) %t_ptr_i8, align 4
  store float %fop_tmp, ptr addrspace(1) %t_ptr_i8, align 4
  ret void
}
