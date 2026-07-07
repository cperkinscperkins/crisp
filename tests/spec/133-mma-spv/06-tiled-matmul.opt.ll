; ModuleID = 'C:/Users/cperk/Documents/crisp-man/tests/spec/133-mma-spv/06-tiled-matmul.temp.ll'
source_filename = "06-tiled-matmul"
target triple = "spir64-unknown-unknown"

%S_06_tiled_matmul_STORAGE_GLOBAL = type { ptr addrspace(1), i64 }
%S_06_tiled_matmul_STORAGE_LOCAL = type { ptr addrspace(3), i64 }

@__spirv_BuiltInLocalInvocationId = local_unnamed_addr addrspace(1) global <3 x i64> zeroinitializer
@__spirv_BuiltInWorkgroupSize = local_unnamed_addr addrspace(1) global <3 x i64> zeroinitializer
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
define spir_func %S_06_tiled_matmul_STORAGE_GLOBAL @parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins
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
define spir_func %S_06_tiled_matmul_STORAGE_GLOBAL @_parent__cell_int_global(ptr addrspace(1) %0, i64 %1, i64 %2) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @_offset__cell_int_global(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 returned %2) local_unnamed_addr #0 {
entry:
  ret i64 %2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func %S_06_tiled_matmul_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins
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
define spir_func %S_06_tiled_matmul_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_last(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @_length__tensor_float_2_global_compact_last(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 returned %8) local_unnamed_addr #0 {
entry:
  ret i64 %8
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func %S_06_tiled_matmul_STORAGE_GLOBAL @parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins
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
define spir_func %S_06_tiled_matmul_STORAGE_GLOBAL @_parent__tensor_float_2_global_compact_first(ptr addrspace(1) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL undef, ptr addrspace(1) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_GLOBAL %ADDRESS_ins, i64 %1, 1
  ret %S_06_tiled_matmul_STORAGE_GLOBAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @_length__tensor_float_2_global_compact_first(ptr addrspace(1) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 returned %8) local_unnamed_addr #0 {
entry:
  ret i64 %8
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func ptr addrspace(3) @address__storage_local(ptr addrspace(3) readnone returned captures(ret: address, provenance) %0, i64 %1) local_unnamed_addr #0 {
entry:
  ret ptr addrspace(3) %0
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @byte_size__storage_local(ptr addrspace(3) readnone captures(none) %0, i64 returned %1) local_unnamed_addr #0 {
entry:
  ret i64 %1
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i32 @address_space__storage_local(ptr addrspace(3) readnone captures(none) %0, i64 %1) local_unnamed_addr #0 {
entry:
  ret i32 3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func ptr addrspace(3) @_address__storage_local(ptr addrspace(3) readnone returned captures(ret: address, provenance) %0, i64 %1) local_unnamed_addr #0 {
entry:
  ret ptr addrspace(3) %0
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @_byte_size__storage_local(ptr addrspace(3) readnone captures(none) %0, i64 returned %1) local_unnamed_addr #0 {
entry:
  ret i64 %1
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func %S_06_tiled_matmul_STORAGE_LOCAL @parent__tensor_float_2_local_compact_last(ptr addrspace(3) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  ret %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @length__tensor_float_2_local_compact_last(ptr addrspace(3) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 returned %8) local_unnamed_addr #0 {
entry:
  ret i64 %8
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i64 @num_dims__tensor_float_2_local_compact_last(ptr addrspace(3) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  ret i64 2
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i32 @address_space__tensor_float_2_local_compact_last(ptr addrspace(3) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  ret i32 3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i32 @align__tensor_float_2_local_compact_last(ptr addrspace(3) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  ret i32 0
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func noundef i32 @contiguous_term__tensor_float_2_local_compact_last(ptr addrspace(3) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  ret i32 0
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func %S_06_tiled_matmul_STORAGE_LOCAL @_parent__tensor_float_2_local_compact_last(ptr addrspace(3) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8) local_unnamed_addr #0 {
entry:
  %ADDRESS_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL undef, ptr addrspace(3) %0, 0
  %BYTE-SIZE_ins = insertvalue %S_06_tiled_matmul_STORAGE_LOCAL %ADDRESS_ins, i64 %1, 1
  ret %S_06_tiled_matmul_STORAGE_LOCAL %BYTE-SIZE_ins
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none)
define spir_func i64 @_length__tensor_float_2_local_compact_last(ptr addrspace(3) readnone captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 returned %8) local_unnamed_addr #0 {
entry:
  ret i64 %8
}

define spir_kernel void @tiled_matmul(ptr addrspace(3) captures(none) %0, i64 %1, i64 %2, i64 %3, i64 %4, i64 %5, i64 %6, i64 %7, i64 %8, ptr addrspace(3) captures(none) %9, i64 %10, i64 %11, i64 %12, i64 %13, i64 %14, i64 %15, i64 %16, i64 %17, ptr addrspace(1) readonly captures(none) %18, i64 %19, i64 %20, i64 %21, i64 %22, i64 %23, i64 %24, i64 %25, i64 %26, ptr addrspace(1) readonly captures(none) %27, i64 %28, i64 %29, i64 %30, i64 %31, i64 %32, i64 %33, i64 %34, i64 %35, ptr addrspace(1) writeonly captures(none) %36, i64 %37, i64 %38, i64 %39, i64 %40, i64 %41, i64 %42, i64 %43, i64 %44) local_unnamed_addr !kernel_arg_addr_space !1 !kernel_arg_access_qual !2 !kernel_arg_type !3 !kernel_arg_base_type !3 !kernel_arg_type_qual !4 {
entry:
  %.fr385 = freeze i64 %7
  %.fr = freeze i64 %16
  %trunc_cast = trunc i64 %25 to i32
  %iop_tmp = sdiv i32 %trunc_cast, 8
  %dt_cond376 = icmp sgt i32 %trunc_cast, 7
  br i1 %dt_cond376, label %dt_body.lr.ph, label %dt_exit

dt_body.lr.ph:                                    ; preds = %entry
  %dt_cond101322.not = icmp eq i64 %15, 0
  %dt_cond113320.not = icmp eq i64 %.fr, 0
  %dt_cond217350.not = icmp eq i64 %6, 0
  %dt_cond235348.not = icmp eq i64 %.fr385, 0
  br label %dt_body

dt_body:                                          ; preds = %dt_body.lr.ph, %dt_exit215
  %kt.0381 = phi i32 [ 0, %dt_body.lr.ph ], [ %i_next449, %dt_exit215 ]
  %"c-tile$f0.sroa.12.0380" = phi float [ 0.000000e+00, %dt_body.lr.ph ], [ %d3, %dt_exit215 ]
  %"c-tile$f0.sroa.0.0379" = phi float [ 0.000000e+00, %dt_body.lr.ph ], [ %d0, %dt_exit215 ]
  %"c-tile$f0.sroa.4.0378" = phi float [ 0.000000e+00, %dt_body.lr.ph ], [ %d1, %dt_exit215 ]
  %"c-tile$f0.sroa.8.0377" = phi float [ 0.000000e+00, %dt_body.lr.ph ], [ %d2, %dt_exit215 ]
  %iop_tmp80 = shl i32 %kt.0381, 3
  %sext_cast = sext i32 %iop_tmp80 to i64
  %localinvocationid_0 = load i64, ptr addrspace(1) @__spirv_BuiltInLocalInvocationId, align 32
  %localinvocationid_1 = load i64, ptr addrspace(1) getelementptr inbounds nuw (i8, ptr addrspace(1) @__spirv_BuiltInLocalInvocationId, i64 8), align 8
  %workgroupsize_0 = load i64, ptr addrspace(1) @__spirv_BuiltInWorkgroupSize, align 32
  %workgroupsize_1 = load i64, ptr addrspace(1) getelementptr inbounds nuw (i8, ptr addrspace(1) @__spirv_BuiltInWorkgroupSize, i64 8), align 8
  br i1 %dt_cond101322.not, label %dt_exit99, label %dt_body98.lr.ph

dt_body98.lr.ph:                                  ; preds = %dt_body
  br i1 %dt_cond113320.not, label %dt_body98, label %dt_body98.us

dt_body98.us:                                     ; preds = %dt_body98.lr.ph, %ifcont.us
  %storemerge323.us = phi i64 [ %i_next185.us, %ifcont.us ], [ 0, %dt_body98.lr.ph ]
  %iop_tmp104.us = add i64 %storemerge323.us, %localinvocationid_0
  %icmp_tmp.us = icmp ult i64 %iop_tmp104.us, %15
  br i1 %icmp_tmp.us, label %dt_check109.preheader.us, label %ifcont.us

ifcont.us:                                        ; preds = %dt_body110.us324, %ifcont124.us.us, %dt_body98.us
  %i_next185.us = add i64 %storemerge323.us, %workgroupsize_0
  %dt_cond101.us = icmp ult i64 %i_next185.us, %15
  br i1 %dt_cond101.us, label %dt_body98.us, label %dt_exit99

dt_body110.us324:                                 ; preds = %dt_check109.preheader.us, %dt_body110.us324
  %storemerge256321.us325 = phi i64 [ %i_next.us344, %dt_body110.us324 ], [ 0, %dt_check109.preheader.us ]
  %iop_tmp116.us326 = add i64 %storemerge256321.us325, %localinvocationid_1
  %icmp_tmp119.us327 = icmp uge i64 %iop_tmp116.us326, %.fr
  tail call void @llvm.assume(i1 %icmp_tmp119.us327)
  %i_next.us344 = add i64 %storemerge256321.us325, %workgroupsize_1
  %dt_cond113.us345 = icmp ult i64 %i_next.us344, %.fr
  br i1 %dt_cond113.us345, label %dt_body110.us324, label %ifcont.us

dt_check109.preheader.us:                         ; preds = %dt_body98.us
  %icmp_tmp129.us = icmp ult i64 %iop_tmp104.us, %24
  %iop_tmp151.us = mul i64 %iop_tmp104.us, %25
  %iop_tmp154.us = add i64 %iop_tmp151.us, %sext_cast
  %iop_tmp161.us = mul i64 %iop_tmp104.us, %.fr
  %icmp_tmp129.fr.us = freeze i1 %icmp_tmp129.us
  br i1 %icmp_tmp129.fr.us, label %dt_body110.us.us, label %dt_body110.us324

dt_body110.us.us:                                 ; preds = %dt_check109.preheader.us, %ifcont124.us.us
  %storemerge256321.us.us = phi i64 [ %i_next.us.us, %ifcont124.us.us ], [ 0, %dt_check109.preheader.us ]
  %iop_tmp116.us.us = add i64 %storemerge256321.us.us, %localinvocationid_1
  %icmp_tmp119.us.us = icmp ult i64 %iop_tmp116.us.us, %.fr
  br i1 %icmp_tmp119.us.us, label %then122.us.us, label %ifcont124.us.us

then122.us.us:                                    ; preds = %dt_body110.us.us
  %iop_tmp137.us.us = add i64 %iop_tmp116.us.us, %sext_cast
  %icmp_tmp139.us.us.not = icmp ult i64 %iop_tmp137.us.us, %25
  br i1 %icmp_tmp139.us.us.not, label %then142.us.us, label %else143.us.us

then142.us.us:                                    ; preds = %then122.us.us
  %iop_tmp155.us.us = add i64 %iop_tmp154.us, %iop_tmp116.us.us
  %t_byte_off.us.us = shl i64 %iop_tmp155.us.us, 2
  %t_ptr_i8.us.us = getelementptr inbounds i8, ptr addrspace(1) %18, i64 %t_byte_off.us.us
  %t_elem.us.us = load float, ptr addrspace(1) %t_ptr_i8.us.us, align 4
  %iop_tmp163.us.us = add i64 %iop_tmp116.us.us, %iop_tmp161.us
  %t_byte_off167.us.us = shl i64 %iop_tmp163.us.us, 2
  %t_ptr_i8168.us.us = getelementptr inbounds i8, ptr addrspace(3) %9, i64 %t_byte_off167.us.us
  store float %t_elem.us.us, ptr addrspace(3) %t_ptr_i8168.us.us, align 4
  br label %ifcont124.us.us

else143.us.us:                                    ; preds = %then122.us.us
  %iop_tmp177.us.us = add i64 %iop_tmp116.us.us, %iop_tmp161.us
  %t_byte_off181.us.us = shl i64 %iop_tmp177.us.us, 2
  %t_ptr_i8182.us.us = getelementptr inbounds i8, ptr addrspace(3) %9, i64 %t_byte_off181.us.us
  store i32 0, ptr addrspace(3) %t_ptr_i8182.us.us, align 4
  br label %ifcont124.us.us

ifcont124.us.us:                                  ; preds = %else143.us.us, %then142.us.us, %dt_body110.us.us
  %i_next.us.us = add i64 %storemerge256321.us.us, %workgroupsize_1
  %dt_cond113.us.us = icmp ult i64 %i_next.us.us, %.fr
  br i1 %dt_cond113.us.us, label %dt_body110.us.us, label %ifcont.us

dt_exit:                                          ; preds = %dt_exit215, %entry
  %"c-tile$f0.sroa.8.0.lcssa" = phi float [ 0.000000e+00, %entry ], [ %d2, %dt_exit215 ]
  %"c-tile$f0.sroa.4.0.lcssa" = phi float [ 0.000000e+00, %entry ], [ %d1, %dt_exit215 ]
  %"c-tile$f0.sroa.0.0.lcssa" = phi float [ 0.000000e+00, %entry ], [ %d0, %dt_exit215 ]
  %"c-tile$f0.sroa.12.0.lcssa" = phi float [ 0.000000e+00, %entry ], [ %d3, %dt_exit215 ]
  %subgrouplocalinvocationid451 = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %subgrouplocalinvocationid451.frozen = freeze i32 %subgrouplocalinvocationid451
  %iop_tmp454 = sdiv i32 %subgrouplocalinvocationid451.frozen, 4
  %45 = mul i32 %iop_tmp454, 4
  %iop_tmp463.decomposed = sub i32 %subgrouplocalinvocationid451.frozen, %45
  %iop_tmp464 = shl nsw i32 %iop_tmp463.decomposed, 1
  %sext_cast471 = sext i32 %iop_tmp454 to i64
  %iop_tmp475 = mul i64 %43, %sext_cast471
  %sext_cast477 = sext i32 %iop_tmp464 to i64
  %iop_tmp478 = add i64 %iop_tmp475, %sext_cast477
  %t_byte_off482 = shl i64 %iop_tmp478, 2
  %t_ptr_i8483 = getelementptr inbounds i8, ptr addrspace(1) %36, i64 %t_byte_off482
  store float %"c-tile$f0.sroa.0.0.lcssa", ptr addrspace(1) %t_ptr_i8483, align 4
  %iop_tmp493 = or disjoint i32 %iop_tmp464, 1
  %sext_cast494 = sext i32 %iop_tmp493 to i64
  %iop_tmp495 = add i64 %iop_tmp475, %sext_cast494
  %t_byte_off499 = shl i64 %iop_tmp495, 2
  %t_ptr_i8500 = getelementptr inbounds i8, ptr addrspace(1) %36, i64 %t_byte_off499
  store float %"c-tile$f0.sroa.4.0.lcssa", ptr addrspace(1) %t_ptr_i8500, align 4
  %iop_tmp504 = add nsw i32 %iop_tmp454, 8
  %sext_cast505 = sext i32 %iop_tmp504 to i64
  %iop_tmp509 = mul i64 %43, %sext_cast505
  %iop_tmp512 = add i64 %iop_tmp509, %sext_cast477
  %t_byte_off516 = shl i64 %iop_tmp512, 2
  %t_ptr_i8517 = getelementptr inbounds i8, ptr addrspace(1) %36, i64 %t_byte_off516
  store float %"c-tile$f0.sroa.8.0.lcssa", ptr addrspace(1) %t_ptr_i8517, align 4
  %iop_tmp530 = add i64 %iop_tmp509, %sext_cast494
  %t_byte_off534 = shl i64 %iop_tmp530, 2
  %t_ptr_i8535 = getelementptr inbounds i8, ptr addrspace(1) %36, i64 %t_byte_off534
  store float %"c-tile$f0.sroa.12.0.lcssa", ptr addrspace(1) %t_ptr_i8535, align 4
  ret void

dt_body98:                                        ; preds = %dt_body98.lr.ph, %dt_body98
  %storemerge323 = phi i64 [ %i_next185, %dt_body98 ], [ 0, %dt_body98.lr.ph ]
  %i_next185 = add i64 %storemerge323, %workgroupsize_0
  %dt_cond101 = icmp ult i64 %i_next185, %15
  br i1 %dt_cond101, label %dt_body98, label %dt_exit99

dt_exit99:                                        ; preds = %ifcont.us, %dt_body98, %dt_body
  tail call void @__spirv_ControlBarrier(i32 2, i32 2, i32 264)
  %localinvocationid_0204 = load i64, ptr addrspace(1) @__spirv_BuiltInLocalInvocationId, align 32
  %localinvocationid_1206 = load i64, ptr addrspace(1) getelementptr inbounds nuw (i8, ptr addrspace(1) @__spirv_BuiltInLocalInvocationId, i64 8), align 8
  %workgroupsize_0208 = load i64, ptr addrspace(1) @__spirv_BuiltInWorkgroupSize, align 32
  %workgroupsize_1210 = load i64, ptr addrspace(1) getelementptr inbounds nuw (i8, ptr addrspace(1) @__spirv_BuiltInWorkgroupSize, i64 8), align 8
  br i1 %dt_cond217350.not, label %dt_exit215, label %dt_body214.lr.ph

dt_body214.lr.ph:                                 ; preds = %dt_exit99
  br i1 %dt_cond235348.not, label %dt_body214, label %dt_body214.us

dt_body214.us:                                    ; preds = %dt_body214.lr.ph, %ifcont228.us
  %storemerge185351.us = phi i64 [ %i_next316.us, %ifcont228.us ], [ 0, %dt_body214.lr.ph ]
  %iop_tmp220.us = add i64 %storemerge185351.us, %localinvocationid_0204
  %icmp_tmp223.us = icmp ult i64 %iop_tmp220.us, %6
  br i1 %icmp_tmp223.us, label %dt_check231.preheader.us, label %ifcont228.us

ifcont228.us:                                     ; preds = %dt_body232.us352, %ifcont246.us.us, %dt_body214.us
  %i_next316.us = add i64 %storemerge185351.us, %workgroupsize_0208
  %dt_cond217.us = icmp ult i64 %i_next316.us, %6
  br i1 %dt_cond217.us, label %dt_body214.us, label %dt_exit215

dt_body232.us352:                                 ; preds = %dt_check231.preheader.us, %dt_body232.us352
  %storemerge192349.us353 = phi i64 [ %i_next314.us372, %dt_body232.us352 ], [ 0, %dt_check231.preheader.us ]
  %iop_tmp238.us354 = add i64 %storemerge192349.us353, %localinvocationid_1206
  %icmp_tmp241.us355 = icmp uge i64 %iop_tmp238.us354, %.fr385
  tail call void @llvm.assume(i1 %icmp_tmp241.us355)
  %i_next314.us372 = add i64 %storemerge192349.us353, %workgroupsize_1210
  %dt_cond235.us373 = icmp ult i64 %i_next314.us372, %.fr385
  br i1 %dt_cond235.us373, label %dt_body232.us352, label %ifcont228.us

dt_check231.preheader.us:                         ; preds = %dt_body214.us
  %iop_tmp249.us = add i64 %iop_tmp220.us, %sext_cast
  %icmp_tmp251.us = icmp ult i64 %iop_tmp249.us, %33
  %iop_tmp275.us = mul i64 %iop_tmp249.us, %34
  %iop_tmp290.us = mul i64 %iop_tmp220.us, %.fr385
  %icmp_tmp251.fr.us = freeze i1 %icmp_tmp251.us
  br i1 %icmp_tmp251.fr.us, label %dt_body232.us.us, label %dt_body232.us352

dt_body232.us.us:                                 ; preds = %dt_check231.preheader.us, %ifcont246.us.us
  %storemerge192349.us.us = phi i64 [ %i_next314.us.us, %ifcont246.us.us ], [ 0, %dt_check231.preheader.us ]
  %iop_tmp238.us.us = add i64 %storemerge192349.us.us, %localinvocationid_1206
  %icmp_tmp241.us.us = icmp ult i64 %iop_tmp238.us.us, %.fr385
  br i1 %icmp_tmp241.us.us, label %then244.us.us, label %ifcont246.us.us

then244.us.us:                                    ; preds = %dt_body232.us.us
  %icmp_tmp262.us.us.not = icmp ult i64 %iop_tmp238.us.us, %34
  br i1 %icmp_tmp262.us.us.not, label %then266.us.us, label %else267.us.us

then266.us.us:                                    ; preds = %then244.us.us
  %iop_tmp279.us.us = add i64 %iop_tmp238.us.us, %iop_tmp275.us
  %t_byte_off283.us.us = shl i64 %iop_tmp279.us.us, 2
  %t_ptr_i8284.us.us = getelementptr inbounds i8, ptr addrspace(1) %27, i64 %t_byte_off283.us.us
  %t_elem285.us.us = load float, ptr addrspace(1) %t_ptr_i8284.us.us, align 4
  %iop_tmp292.us.us = add i64 %iop_tmp238.us.us, %iop_tmp290.us
  %t_byte_off296.us.us = shl i64 %iop_tmp292.us.us, 2
  %t_ptr_i8297.us.us = getelementptr inbounds i8, ptr addrspace(3) %0, i64 %t_byte_off296.us.us
  store float %t_elem285.us.us, ptr addrspace(3) %t_ptr_i8297.us.us, align 4
  br label %ifcont246.us.us

else267.us.us:                                    ; preds = %then244.us.us
  %iop_tmp306.us.us = add i64 %iop_tmp238.us.us, %iop_tmp290.us
  %t_byte_off310.us.us = shl i64 %iop_tmp306.us.us, 2
  %t_ptr_i8311.us.us = getelementptr inbounds i8, ptr addrspace(3) %0, i64 %t_byte_off310.us.us
  store i32 0, ptr addrspace(3) %t_ptr_i8311.us.us, align 4
  br label %ifcont246.us.us

ifcont246.us.us:                                  ; preds = %else267.us.us, %then266.us.us, %dt_body232.us.us
  %i_next314.us.us = add i64 %storemerge192349.us.us, %workgroupsize_1210
  %dt_cond235.us.us = icmp ult i64 %i_next314.us.us, %.fr385
  br i1 %dt_cond235.us.us, label %dt_body232.us.us, label %ifcont228.us

dt_body214:                                       ; preds = %dt_body214.lr.ph, %dt_body214
  %storemerge185351 = phi i64 [ %i_next316, %dt_body214 ], [ 0, %dt_body214.lr.ph ]
  %i_next316 = add i64 %storemerge185351, %workgroupsize_0208
  %dt_cond217 = icmp ult i64 %i_next316, %6
  br i1 %dt_cond217, label %dt_body214, label %dt_exit215

dt_exit215:                                       ; preds = %ifcont228.us, %dt_body214, %dt_exit99
  tail call void @__spirv_ControlBarrier(i32 2, i32 2, i32 264)
  tail call void @__spirv_ControlBarrier(i32 2, i32 2, i32 264)
  %subgrouplocalinvocationid = load i32, ptr addrspace(1) @__spirv_BuiltInSubgroupLocalInvocationId, align 4
  %subgrouplocalinvocationid.frozen = freeze i32 %subgrouplocalinvocationid
  %iop_tmp319 = sdiv i32 %subgrouplocalinvocationid.frozen, 4
  %46 = mul i32 %iop_tmp319, 4
  %iop_tmp327.decomposed = sub i32 %subgrouplocalinvocationid.frozen, %46
  %sext_cast334 = sext i32 %iop_tmp319 to i64
  %iop_tmp338 = mul i64 %.fr, %sext_cast334
  %sext_cast340 = sext i32 %iop_tmp327.decomposed to i64
  %iop_tmp341 = add i64 %iop_tmp338, %sext_cast340
  %t_byte_off345 = shl i64 %iop_tmp341, 2
  %t_ptr_i8346 = getelementptr inbounds i8, ptr addrspace(3) %9, i64 %t_byte_off345
  %t_elem347186 = load i32, ptr addrspace(3) %t_ptr_i8346, align 4
  %iop_tmp349 = add nsw i32 %iop_tmp319, 8
  %sext_cast350 = sext i32 %iop_tmp349 to i64
  %iop_tmp354 = mul i64 %.fr, %sext_cast350
  %iop_tmp357 = add i64 %iop_tmp354, %sext_cast340
  %t_byte_off361 = shl i64 %iop_tmp357, 2
  %t_ptr_i8362 = getelementptr inbounds i8, ptr addrspace(3) %9, i64 %t_byte_off361
  %t_elem363187 = load i32, ptr addrspace(3) %t_ptr_i8362, align 4
  %iop_tmp371 = add nsw i32 %iop_tmp327.decomposed, 4
  %sext_cast372 = zext nneg i32 %iop_tmp371 to i64
  %iop_tmp373 = add i64 %iop_tmp338, %sext_cast372
  %t_byte_off377 = shl i64 %iop_tmp373, 2
  %t_ptr_i8378 = getelementptr inbounds i8, ptr addrspace(3) %9, i64 %t_byte_off377
  %t_elem379188 = load i32, ptr addrspace(3) %t_ptr_i8378, align 4
  %iop_tmp390 = add i64 %iop_tmp354, %sext_cast372
  %t_byte_off394 = shl i64 %iop_tmp390, 2
  %t_ptr_i8395 = getelementptr inbounds i8, ptr addrspace(3) %9, i64 %t_byte_off394
  %t_elem396189 = load i32, ptr addrspace(3) %t_ptr_i8395, align 4
  %iop_tmp422 = mul i64 %.fr385, %sext_cast340
  %iop_tmp425 = add i64 %iop_tmp422, %sext_cast334
  %t_byte_off429 = shl i64 %iop_tmp425, 2
  %t_ptr_i8430 = getelementptr inbounds i8, ptr addrspace(3) %0, i64 %t_byte_off429
  %t_elem431190 = load i32, ptr addrspace(3) %t_ptr_i8430, align 4
  %iop_tmp438 = mul i64 %.fr385, %sext_cast372
  %iop_tmp441 = add i64 %iop_tmp438, %sext_cast334
  %t_byte_off445 = shl i64 %iop_tmp441, 2
  %t_ptr_i8446 = getelementptr inbounds i8, ptr addrspace(3) %0, i64 %t_byte_off445
  %t_elem447191 = load i32, ptr addrspace(3) %t_ptr_i8446, align 4
  %mma = tail call { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32 %t_elem347186, i32 %t_elem363187, i32 %t_elem379188, i32 %t_elem396189, i32 %t_elem431190, i32 %t_elem447191, float %"c-tile$f0.sroa.0.0379", float %"c-tile$f0.sroa.4.0378", float %"c-tile$f0.sroa.8.0377", float %"c-tile$f0.sroa.12.0380")
  %d0 = extractvalue { float, float, float, float } %mma, 0
  %d1 = extractvalue { float, float, float, float } %mma, 1
  %d2 = extractvalue { float, float, float, float } %mma, 2
  %d3 = extractvalue { float, float, float, float } %mma, 3
  tail call void @__spirv_ControlBarrier(i32 2, i32 2, i32 264)
  %i_next449 = add nuw nsw i32 %kt.0381, 1
  %dt_cond = icmp slt i32 %i_next449, %iop_tmp
  br i1 %dt_cond, label %dt_body, label %dt_exit
}

declare void @__spirv_ControlBarrier(i32, i32, i32) local_unnamed_addr

; Function Attrs: nocallback nofree nosync nounwind memory(none)
declare { float, float, float, float } @llvm.nvvm.mma.m16n8k8.row.col.tf32(i32, i32, i32, i32, i32, i32, float, float, float, float) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #2

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) "denormal-fp-math"="ieee,ieee" "denormal-fp-math-f32"="ieee,ieee" }
attributes #1 = { nocallback nofree nosync nounwind memory(none) }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }

!spirv.ExecutionMode = !{!0}

!0 = !{ptr @tiled_matmul, i32 4459, i32 32}
!1 = !{i32 3, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 3, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0}
!2 = !{!"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none", !"none"}
!3 = !{!"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"int*", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong", !"ulong"}
!4 = !{!"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !"", !""}
