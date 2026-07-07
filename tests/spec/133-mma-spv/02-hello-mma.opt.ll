; ModuleID = 'C:/Users/cperk/Documents/crisp-man/tests/spec/133-mma-spv/02-hello-mma.temp.ll'
source_filename = "02-hello-mma"
target triple = "spir64-unknown-unknown"

%S_02_hello_mma_STORAGE_GLOBAL = type { ptr addrspace(1), i64 }

@__spirv_BuiltInSubgroupLocalInvocationId = local_unnamed_addr addrspace(1) global i32 0

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func ptr addrspace(1) @address__storage_global(ptr addrspace(1) readnone returned captures(ret: address, provenance) %0, i64 %1) local_unnamed_addr #0 {
entry:
  ret ptr addrspace(1) %0
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @byte_size__storage_global(ptr addrspace(1) readnone captures(none) %0, i64 returned %1) local_unnamed_addr #0 {
entry:
  ret i64 %1
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i32 @address_space__storage_global(ptr addrspace(1) readnone captures(none) %0, i64 %1) local_unnamed_addr #0 {
entry:
  ret i32 1
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func ptr addrspace(1) @_address__storage_global(ptr addrspace(1) readnone returned captures(ret: address, provenance) %0, i64 %1) local_unnamed_addr #0 {
entry:
  ret ptr addrspace(1) %0
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @_byte_size__storage_global(ptr addrspace(1) readnone captures(none) %0, i64 returned %1) local_unnamed_addr #0 {
entry:
  ret i64 %1
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func %S_02_hello_mma_STORAGE_GLOBAL @parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @offset__cell_int_global(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 returned %2) local_unnamed_addr #0 {
entry:
  ret i64 %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i32 @address_space__cell_int_global(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2) local_unnamed_addr #0 {
entry:
  ret i32 1
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func %S_02_hello_mma_STORAGE_GLOBAL @_parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @_offset__cell_int_global(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 returned %2) local_unnamed_addr #0 {
entry:
  ret i64 %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func %S_02_hello_mma_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @length__tensor_float_2_global_compact_last(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 returned %8) local_unnamed_addr #0 {
entry:
  ret i64 %8
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i64 @num_dims__tensor_float_2_global_compact_last(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  ret i64 2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i32 @address_space__tensor_float_2_global_compact_last(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  ret i32 1
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i32 @align__tensor_float_2_global_compact_last(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  ret i32 0
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i32 @contiguous_term__tensor_float_2_global_compact_last(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  ret i32 0
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func %S_02_hello_mma_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @_length__tensor_float_2_global_compact_last(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 returned %8) local_unnamed_addr #0 {
entry:
  ret i64 %8
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func %S_02_hello_mma_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @length__tensor_float_2_global_compact_first(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 returned %8) local_unnamed_addr #0 {
entry:
  ret i64 %8
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i64 @num_dims__tensor_float_2_global_compact_first(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  ret i64 2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i32 @address_space__tensor_float_2_global_compact_first(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  ret i32 1
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i32 @align__tensor_float_2_global_compact_first(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  ret i32 0
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i32 @contiguous_term__tensor_float_2_global_compact_first(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  ret i32 1
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func %S_02_hello_mma_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_02_hello_mma_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_02_hello_mma_STORAGE_GLOBAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @_length__tensor_float_2_global_compact_first(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 returned %8) local_unnamed_addr #0 {
entry:
  ret i64 %8
}

; Function Attrs: nofree norecurse nosync nounwind memory(read, argmem: readwrite, inaccessiblemem: none)
define spir_kernel void @hello_mma(ptr addrspace(1) readonly captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8, ptr addrspace(1) readonly captures(none) %9, i64 %10, i64 %11, i64 %12, i64 %13, i64 %14, i64 %15, i64 %16, i64 %17, ptr addrspace(1) writeonly captures(none) %18, i64 %19, i64 %20, i64 %21, i64 %22, i64 %23, i64 %24, i64 %25, i64 %26) local_unnamed_addr #1 !kernel_arg_addr_space !1 !kernel_arg_access_qual !2 !kernel_arg_type !3 !kernel_arg_base_type !3 !kernel_arg_type_qual !4 {
entry:
  %subgrouplocalinvocationid = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %iop_tmp = sdiv i32 %subgrouplocalinvocationid, 4
  %iop_tmp65 = shl nsw i32 %iop_tmp, 2
  %iop_tmp66 = sub i32 %subgrouplocalinvocationid, %iop_tmp65
  %sext_cast = sext i32 %iop_tmp to i64
  %iop_tmp73 = mul i64 %7, %sext_cast
  %sext_cast75 = sext i32 %iop_tmp66 to i64
  %iop_tmp76 = add i64 %iop_tmp73, %sext_cast75
  %t_byte_off = shl i64 %iop_tmp76, 2
  %t_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %0, i64 %t_byte_off
  %t_elem90 = load i32, ptr addrspace(1) %t_ptr_i8, align 4, !invariant.load !5
  %iop_tmp79 = add nsw i32 %iop_tmp, 8
  %sext_cast80 = sext i32 %iop_tmp79 to i64
  %iop_tmp84 = mul i64 %7, %sext_cast80
  %iop_tmp87 = add i64 %iop_tmp84, %sext_cast75
  %t_byte_off91 = shl i64 %iop_tmp87, 2
  %t_ptr_i892 = getelementptr inbounds i8, ptr addrspace(1) %0, i64 %t_byte_off91
  %t_elem9391 = load i32, ptr addrspace(1) %t_ptr_i892, align 4, !invariant.load !5
  %iop_tmp101 = add i32 %iop_tmp66, 4
  %sext_cast102 = sext i32 %iop_tmp101 to i64
  %iop_tmp103 = add i64 %iop_tmp73, %sext_cast102
  %t_byte_off107 = shl i64 %iop_tmp103, 2
  %t_ptr_i8108 = getelementptr inbounds i8, ptr addrspace(1) %0, i64 %t_byte_off107
  %t_elem10992 = load i32, ptr addrspace(1) %t_ptr_i8108, align 4, !invariant.load !5
  %iop_tmp120 = add i64 %iop_tmp84, %sext_cast102
  %t_byte_off124 = shl i64 %iop_tmp120, 2
  %t_ptr_i8125 = getelementptr inbounds i8, ptr addrspace(1) %0, i64 %t_byte_off124
  %t_elem12693 = load i32, ptr addrspace(1) %t_ptr_i8125, align 4, !invariant.load !5
  %iop_tmp152 = mul i64 %16, %sext_cast75
  %iop_tmp155 = add i64 %iop_tmp152, %sext_cast
  %t_byte_off159 = shl i64 %iop_tmp155, 2
  %t_ptr_i8160 = getelementptr inbounds i8, ptr addrspace(1) %9, i64 %t_byte_off159
  %t_elem16194 = load i32, ptr addrspace(1) %t_ptr_i8160, align 4, !invariant.load !5
  %iop_tmp168 = mul i64 %16, %sext_cast102
  %iop_tmp171 = add i64 %iop_tmp168, %sext_cast
  %t_byte_off175 = shl i64 %iop_tmp171, 2
  %t_ptr_i8176 = getelementptr inbounds i8, ptr addrspace(1) %9, i64 %t_byte_off175
  %t_elem17795 = load i32, ptr addrspace(1) %t_ptr_i8176, align 4, !invariant.load !5
  %mma = tail call { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32 %t_elem90, i32 %t_elem9391, i32 %t_elem10992, i32 %t_elem12693, i32 %t_elem16194, i32 %t_elem17795, float 0.000000e+00, float 0.000000e+00, float 0.000000e+00, float 0.000000e+00)
  %d0 = extractvalue { float, float, float, float } %mma, 0
  %d1 = extractvalue { float, float, float, float } %mma, 1
  %d2 = extractvalue { float, float, float, float } %mma, 2
  %d3 = extractvalue { float, float, float, float } %mma, 3
  %iop_tmp194 = shl i32 %iop_tmp66, 1
  %iop_tmp205 = mul i64 %25, %sext_cast
  %sext_cast207 = sext i32 %iop_tmp194 to i64
  %iop_tmp208 = add i64 %iop_tmp205, %sext_cast207
  %t_byte_off212 = shl i64 %iop_tmp208, 2
  %t_ptr_i8213 = getelementptr inbounds i8, ptr addrspace(1) %18, i64 %t_byte_off212
  store float %d0, ptr addrspace(1) %t_ptr_i8213, align 4
  %iop_tmp223 = or disjoint i32 %iop_tmp194, 1
  %sext_cast224 = sext i32 %iop_tmp223 to i64
  %iop_tmp225 = add i64 %iop_tmp205, %sext_cast224
  %t_byte_off229 = shl i64 %iop_tmp225, 2
  %t_ptr_i8230 = getelementptr inbounds i8, ptr addrspace(1) %18, i64 %t_byte_off229
  store float %d1, ptr addrspace(1) %t_ptr_i8230, align 4
  %iop_tmp239 = mul i64 %25, %sext_cast80
  %iop_tmp242 = add i64 %iop_tmp239, %sext_cast207
  %t_byte_off246 = shl i64 %iop_tmp242, 2
  %t_ptr_i8247 = getelementptr inbounds i8, ptr addrspace(1) %18, i64 %t_byte_off246
  store float %d2, ptr addrspace(1) %t_ptr_i8247, align 4
  %iop_tmp260 = add i64 %iop_tmp239, %sext_cast224
  %t_byte_off264 = shl i64 %iop_tmp260, 2
  %t_ptr_i8265 = getelementptr inbounds i8, ptr addrspace(1) %18, i64 %t_byte_off264
  store float %d3, ptr addrspace(1) %t_ptr_i8265, align 4
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind memory(none)
declare { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32, i32, i32, i32, i32, i32, float, float, float, float) #2

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) "denormal-fp-math"="ieee,ieee" "denormal-fp-math-f32"="ieee,ieee" }
attributes #1 = { nofree norecurse nosync nounwind memory(read, argmem: readwrite, inaccessiblemem: none) }
attributes #2 = { nocallback nofree nosync nounwind memory(none) }

!spirv.ExecutionMode = !{!0}

!0 = !{ptr @hello_mma, i32 4459, i32 32}
!1 = !{i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0}
!2 = !{!"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none"}
!3 = !{!"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong"}
!4 = !{!"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !""}
!5 = !{}
