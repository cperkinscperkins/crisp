# Shop Local, Act Global


A VERY common practice among GPU algorithm writers is "shop local, act global". In this
practice a small amount of local memory (usually one cell per workgroup thread) is operated
upon by the workgroup, and then one leader thread from the work group performs some 
operation that touches global memory (like an atomic operation).

We will see this practice over and over and over.  The reductions do it, the filter and scans,
the sorting, and more.  Crisp usually provides very useful reusable macros for the workgroup level,
and ready-to-go routines that employ them at the global level. 


