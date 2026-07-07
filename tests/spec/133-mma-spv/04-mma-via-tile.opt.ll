; ModuleID = 'C:/Users/cperk/Documents/crisp-man/tests/spec/133-mma-spv/04-mma-via-tile.temp.ll'
source_filename = "04-mma-via-tile"
target triple = "spir64-unknown-unknown"

%S_04_mma_via_tile_STORAGE_GLOBAL = type { ptr addrspace(1), i64 }

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
define spir_func %S_04_mma_via_tile_STORAGE_GLOBAL @parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins
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
define spir_func %S_04_mma_via_tile_STORAGE_GLOBAL @_parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @_offset__cell_int_global(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 returned %2) local_unnamed_addr #0 {
entry:
  ret i64 %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func %S_04_mma_via_tile_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins
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
define spir_func %S_04_mma_via_tile_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @_length__tensor_float_2_global_compact_last(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 returned %8) local_unnamed_addr #0 {
entry:
  ret i64 %8
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func %S_04_mma_via_tile_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins
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
define spir_func %S_04_mma_via_tile_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_04_mma_via_tile_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_04_mma_via_tile_STORAGE_GLOBAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @_length__tensor_float_2_global_compact_first(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 returned %8) local_unnamed_addr #0 {
entry:
  ret i64 %8
}

; Function Attrs: nofree norecurse nosync nounwind memory(read, argmem: readwrite, inaccessiblemem: none)
define spir_kernel void @via_tile(ptr addrspace(1) readonly captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8, ptr addrspace(1) readonly captures(none) %9, i64 %10, i64 %11, i64 %12, i64 %13, i64 %14, i64 %15, i64 %16, i64 %17, ptr addrspace(1) writeonly captures(none) %18, i64 %19, i64 %20, i64 %21, i64 %22, i64 %23, i64 %24, i64 %25, i64 %26) local_unnamed_addr #1 !kernel_arg_addr_space !1 !kernel_arg_access_qual !2 !kernel_arg_type !3 !kernel_arg_base_type !3 !kernel_arg_type_qual !4 {
entry:
  %subgrouplocalinvocationid = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %iop_tmp = sdiv i32 %subgrouplocalinvocationid, 4
  %iop_tmp66 = shl nsw i32 %iop_tmp, 2
  %iop_tmp67 = sub i32 %subgrouplocalinvocationid, %iop_tmp66
  %sext_cast = sext i32 %iop_tmp to i64
  %iop_tmp74 = mul i64 %7, %sext_cast
  %sext_cast76 = sext i32 %iop_tmp67 to i64
  %iop_tmp77 = add i64 %iop_tmp74, %sext_cast76
  %t_byte_off = shl i64 %iop_tmp77, 2
  %t_ptr_i8 = getelementptr inbounds i8, ptr addrspace(1) %0, i64 %t_byte_off
  %t_elem90 = load i32, ptr addrspace(1) %t_ptr_i8, align 4, !invariant.load !5
  %iop_tmp80 = add nsw i32 %iop_tmp, 8
  %sext_cast81 = sext i32 %iop_tmp80 to i64
  %iop_tmp85 = mul i64 %7, %sext_cast81
  %iop_tmp88 = add i64 %iop_tmp85, %sext_cast76
  %t_byte_off92 = shl i64 %iop_tmp88, 2
  %t_ptr_i893 = getelementptr inbounds i8, ptr addrspace(1) %0, i64 %t_byte_off92
  %t_elem9491 = load i32, ptr addrspace(1) %t_ptr_i893, align 4, !invariant.load !5
  %iop_tmp102 = add i32 %iop_tmp67, 4
  %sext_cast103 = sext i32 %iop_tmp102 to i64
  %iop_tmp104 = add i64 %iop_tmp74, %sext_cast103
  %t_byte_off108 = shl i64 %iop_tmp104, 2
  %t_ptr_i8109 = getelementptr inbounds i8, ptr addrspace(1) %0, i64 %t_byte_off108
  %t_elem11092 = load i32, ptr addrspace(1) %t_ptr_i8109, align 4, !invariant.load !5
  %iop_tmp121 = add i64 %iop_tmp85, %sext_cast103
  %t_byte_off125 = shl i64 %iop_tmp121, 2
  %t_ptr_i8126 = getelementptr inbounds i8, ptr addrspace(1) %0, i64 %t_byte_off125
  %t_elem12793 = load i32, ptr addrspace(1) %t_ptr_i8126, align 4, !invariant.load !5
  %iop_tmp153 = mul i64 %16, %sext_cast76
  %iop_tmp156 = add i64 %iop_tmp153, %sext_cast
  %t_byte_off160 = shl i64 %iop_tmp156, 2
  %t_ptr_i8161 = getelementptr inbounds i8, ptr addrspace(1) %9, i64 %t_byte_off160
  %t_elem16294 = load i32, ptr addrspace(1) %t_ptr_i8161, align 4, !invariant.load !5
  %iop_tmp169 = mul i64 %16, %sext_cast103
  %iop_tmp172 = add i64 %iop_tmp169, %sext_cast
  %t_byte_off176 = shl i64 %iop_tmp172, 2
  %t_ptr_i8177 = getelementptr inbounds i8, ptr addrspace(1) %9, i64 %t_byte_off176
  %t_elem17895 = load i32, ptr addrspace(1) %t_ptr_i8177, align 4, !invariant.load !5
  %mma = tail call { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32 %t_elem90, i32 %t_elem9491, i32 %t_elem11092, i32 %t_elem12793, i32 %t_elem16294, i32 %t_elem17895, float 0.000000e+00, float 0.000000e+00, float 0.000000e+00, float 0.000000e+00)
  %d0 = extractvalue { float, float, float, float } %mma, 0
  %d1 = extractvalue { float, float, float, float } %mma, 1
  %d2 = extractvalue { float, float, float, float } %mma, 2
  %d3 = extractvalue { float, float, float, float } %mma, 3
  %iop_tmp193 = shl i32 %iop_tmp67, 1
  %iop_tmp204 = mul i64 %25, %sext_cast
  %sext_cast206 = sext i32 %iop_tmp193 to i64
  %iop_tmp207 = add i64 %iop_tmp204, %sext_cast206
  %t_byte_off211 = shl i64 %iop_tmp207, 2
  %t_ptr_i8212 = getelementptr inbounds i8, ptr addrspace(1) %18, i64 %t_byte_off211
  store float %d0, ptr addrspace(1) %t_ptr_i8212, align 4
  %iop_tmp222 = or disjoint i32 %iop_tmp193, 1
  %sext_cast223 = sext i32 %iop_tmp222 to i64
  %iop_tmp224 = add i64 %iop_tmp204, %sext_cast223
  %t_byte_off228 = shl i64 %iop_tmp224, 2
  %t_ptr_i8229 = getelementptr inbounds i8, ptr addrspace(1) %18, i64 %t_byte_off228
  store float %d1, ptr addrspace(1) %t_ptr_i8229, align 4
  %iop_tmp238 = mul i64 %25, %sext_cast81
  %iop_tmp241 = add i64 %iop_tmp238, %sext_cast206
  %t_byte_off245 = shl i64 %iop_tmp241, 2
  %t_ptr_i8246 = getelementptr inbounds i8, ptr addrspace(1) %18, i64 %t_byte_off245
  store float %d2, ptr addrspace(1) %t_ptr_i8246, align 4
  %iop_tmp259 = add i64 %iop_tmp238, %sext_cast223
  %t_byte_off263 = shl i64 %iop_tmp259, 2
  %t_ptr_i8264 = getelementptr inbounds i8, ptr addrspace(1) %18, i64 %t_byte_off263
  store float %d3, ptr addrspace(1) %t_ptr_i8264, align 4
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind memory(none)
declare { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32, i32, i32, i32, i32, i32, float, float, float, float) #2

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) "denormal-fp-math"="ieee,ieee" "denormal-fp-math-f32"="ieee,ieee" }
attributes #1 = { nofree norecurse nosync nounwind memory(read, argmem: readwrite, inaccessiblemem: none) }
attributes #2 = { nocallback nofree nosync nounwind memory(none) }

!spirv.ExecutionMode = !{!0}

!0 = !{ptr @via_tile, i32 4459, i32 32}
!1 = !{i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0}
!2 = !{!"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none"}
!3 = !{!"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong"}
!4 = !{!"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !""}
!5 = !{}
