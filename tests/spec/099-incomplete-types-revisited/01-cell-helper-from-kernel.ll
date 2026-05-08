; ModuleID = '01-cell-helper-from-kernel'
source_filename = "01-cell-helper-from-kernel"

%STORAGE_GLOBAL = type { ptr addrspace(1), i64 }
%CELL_FLOAT_GLOBAL = type { %STORAGE_GLOBAL, i64 }

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

define %STORAGE_GLOBAL @parent__cell_float_global(ptr addrspace(1) %0, i64 %1, i64 %2) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %CELL_FLOAT_GLOBAL undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %CELL_FLOAT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %CELL_FLOAT_GLOBAL, align 8
  store %CELL_FLOAT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %CELL_FLOAT_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %CELL_FLOAT_GLOBAL %obj1, 0
  ret %STORAGE_GLOBAL %extract_0
}

define i64 @offset__cell_float_global(ptr addrspace(1) %0, i64 %1, i64 %2) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %CELL_FLOAT_GLOBAL undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %CELL_FLOAT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %CELL_FLOAT_GLOBAL, align 8
  store %CELL_FLOAT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %CELL_FLOAT_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %CELL_FLOAT_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define i32 @address_space__cell_float_global(ptr addrspace(1) %0, i64 %1, i64 %2) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %CELL_FLOAT_GLOBAL undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %CELL_FLOAT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %CELL_FLOAT_GLOBAL, align 8
  store %CELL_FLOAT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  ret i32 1
}

define %STORAGE_GLOBAL @_parent__cell_float_global(ptr addrspace(1) %0, i64 %1, i64 %2) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %CELL_FLOAT_GLOBAL undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %CELL_FLOAT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %CELL_FLOAT_GLOBAL, align 8
  store %CELL_FLOAT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %CELL_FLOAT_GLOBAL, ptr %obj, align 8
  %extract_0 = extractvalue %CELL_FLOAT_GLOBAL %obj1, 0
  ret %STORAGE_GLOBAL %extract_0
}

define i64 @_offset__cell_float_global(ptr addrspace(1) %0, i64 %1, i64 %2) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %CELL_FLOAT_GLOBAL undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %CELL_FLOAT_GLOBAL %PARENT_ins, i64 %2, 1
  %obj = alloca %CELL_FLOAT_GLOBAL, align 8
  store %CELL_FLOAT_GLOBAL %OFFSET_ins, ptr %obj, align 8
  %obj1 = load %CELL_FLOAT_GLOBAL, ptr %obj, align 8
  %extract_1 = extractvalue %CELL_FLOAT_GLOBAL %obj1, 1
  ret i64 %extract_1
}

define float @read_cell_cell_float_global(ptr addrspace(1) %0, i64 %1, i64 %2) {
entry:
  %ADDRESS_ins = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  %PARENT_ins = insertvalue %CELL_FLOAT_GLOBAL undef, %STORAGE_GLOBAL %BYTE-SIZE_ins, 0
  %OFFSET_ins = insertvalue %CELL_FLOAT_GLOBAL %PARENT_ins, i64 %2, 1
  %c = alloca %CELL_FLOAT_GLOBAL, align 8
  store %CELL_FLOAT_GLOBAL %OFFSET_ins, ptr %c, align 8
  %c1 = load %CELL_FLOAT_GLOBAL, ptr %c, align 8
  %parent_val = extractvalue %CELL_FLOAT_GLOBAL %c1, 0
  %base_ptr = extractvalue %STORAGE_GLOBAL %parent_val, 0
  %cell_offset = extractvalue %CELL_FLOAT_GLOBAL %c1, 1
  %total_offset = add i64 %cell_offset, 0
  %final_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %base_ptr, i64 %total_offset
  %val = load float, ptr addrspace(1) %final_ptr_i8, align 4
  ret float %val
}

define void @cell_helper_test(ptr addrspace(1) %0, i64 %1, i64 %2, ptr addrspace(1) %3, i64 %4, i64 %5) {
entry:
  %a_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %0, ptr %a_ptr, align 8
  %a_byte_size = alloca i64, align 8
  store i64 %1, ptr %a_byte_size, align 4
  %a_offset = alloca i64, align 8
  store i64 %2, ptr %a_offset, align 4
  %c_ptr = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %3, ptr %c_ptr, align 8
  %c_byte_size = alloca i64, align 8
  store i64 %4, ptr %c_byte_size, align 4
  %c_offset = alloca i64, align 8
  store i64 %5, ptr %c_offset, align 4
  %a_ptr1 = load ptr addrspace(1), ptr %a_ptr, align 8
  %insert_ADDRESS = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %a_ptr1, 0
  %a_byte_size2 = load i64, ptr %a_byte_size, align 4
  %insert_BYTE-SIZE = insertvalue %STORAGE_GLOBAL %insert_ADDRESS, i64 %a_byte_size2, 1
  %insert_PARENT = insertvalue %CELL_FLOAT_GLOBAL undef, %STORAGE_GLOBAL %insert_BYTE-SIZE, 0
  %a_offset3 = load i64, ptr %a_offset, align 4
  %insert_OFFSET = insertvalue %CELL_FLOAT_GLOBAL %insert_PARENT, i64 %a_offset3, 1
  %a = alloca %CELL_FLOAT_GLOBAL, align 8
  store %CELL_FLOAT_GLOBAL %insert_OFFSET, ptr %a, align 8
  %c_ptr4 = load ptr addrspace(1), ptr %c_ptr, align 8
  %insert_ADDRESS5 = insertvalue %STORAGE_GLOBAL undef, ptr addrspace(1) %c_ptr4, 0
  %c_byte_size6 = load i64, ptr %c_byte_size, align 4
  %insert_BYTE-SIZE7 = insertvalue %STORAGE_GLOBAL %insert_ADDRESS5, i64 %c_byte_size6, 1
  %insert_PARENT8 = insertvalue %CELL_FLOAT_GLOBAL undef, %STORAGE_GLOBAL %insert_BYTE-SIZE7, 0
  %c_offset9 = load i64, ptr %c_offset, align 4
  %insert_OFFSET10 = insertvalue %CELL_FLOAT_GLOBAL %insert_PARENT8, i64 %c_offset9, 1
  %c = alloca %CELL_FLOAT_GLOBAL, align 8
  store %CELL_FLOAT_GLOBAL %insert_OFFSET10, ptr %c, align 8
  %a11 = load %CELL_FLOAT_GLOBAL, ptr %a, align 8
  %PARENT_val = extractvalue %CELL_FLOAT_GLOBAL %a11, 0
  %ADDRESS_val = extractvalue %STORAGE_GLOBAL %PARENT_val, 0
  %BYTE-SIZE_val = extractvalue %STORAGE_GLOBAL %PARENT_val, 1
  %OFFSET_val = extractvalue %CELL_FLOAT_GLOBAL %a11, 1
  %call_tmp = call float @read_cell_cell_float_global(ptr addrspace(1) %ADDRESS_val, i64 %BYTE-SIZE_val, i64 %OFFSET_val)
  %c12 = load %CELL_FLOAT_GLOBAL, ptr %c, align 8
  %parent_val = extractvalue %CELL_FLOAT_GLOBAL %c12, 0
  %base_ptr = extractvalue %STORAGE_GLOBAL %parent_val, 0
  %cell_offset = extractvalue %CELL_FLOAT_GLOBAL %c12, 1
  %total_offset = add i64 %cell_offset, 0
  %final_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %base_ptr, i64 %total_offset
  %val = load float, ptr addrspace(1) %final_ptr_i8, align 4
  store float %call_tmp, ptr addrspace(1) %final_ptr_i8, align 4
  ret void
}
