# Automatic Differentiation over the FFI Boundary


To use a foreign function within a differentiated kernel, provide its backward pass as the third
argument to `def-foreign-function`. The compiler derives the required signature of that backward
function from the forward signature using the VJP rule below.


