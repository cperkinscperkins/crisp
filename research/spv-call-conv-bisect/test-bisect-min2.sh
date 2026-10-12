#!/bin/bash
. /opt/intel/oneapi/setvars.sh > /dev/null 2>&1

probe() {
    local desc="$1"
    local ll="$2"
    echo "=== $desc ==="
    cat > /tmp/in.ll << EOF
$ll
EOF
    opt -passes='function(instcombine)' -S /tmp/in.ll -o /tmp/out.ll 2>/dev/null
    if [ ! -f /tmp/out.ll ]; then
        echo "(opt failed)"
        opt -passes='function(instcombine)' -S /tmp/in.ll -o /tmp/out.ll 2>&1 | head -3
        return
    fi
    awk '/^define spir_kernel.*@vec_copy/,/^}/' /tmp/out.ll
    echo "---"
}

HEADER='target triple = "spir64-unknown-unknown"'

probe "T4: with call (alloca + load + call)" "$HEADER
define spir_func i64 @leng(i64 %0) {
entry:
  ret i64 %0
}
define spir_kernel void @vec_copy(i64 %5) {
entry:
  %a_length = alloca i64, align 8
  store i64 %5, ptr %a_length, align 4
  %v = load i64, ptr %a_length, align 4
  %call_tmp = call i64 @leng(i64 %v)
  %cond = icmp uge i64 %5, %call_tmp
  br i1 %cond, label %then, label %else
then:
  br label %ifcont
else:
  br label %ifcont
ifcont:
  ret void
}"

probe "T5: NO call, but icmp uge x, x" "$HEADER
define spir_kernel void @vec_copy(i64 %5) {
entry:
  %a_length = alloca i64, align 8
  store i64 %5, ptr %a_length, align 4
  %v = load i64, ptr %a_length, align 4
  %cond = icmp uge i64 %5, %v
  br i1 %cond, label %then, label %else
then:
  br label %ifcont
else:
  br label %ifcont
ifcont:
  ret void
}"

probe "T6: call but no alloca/store/load chain" "$HEADER
define spir_func i64 @leng(i64 %0) {
entry:
  ret i64 %0
}
define spir_kernel void @vec_copy(i64 %5) {
entry:
  %call_tmp = call i64 @leng(i64 %5)
  %cond = icmp uge i64 %5, %call_tmp
  br i1 %cond, label %then, label %else
then:
  br label %ifcont
else:
  br label %ifcont
ifcont:
  ret void
}"
