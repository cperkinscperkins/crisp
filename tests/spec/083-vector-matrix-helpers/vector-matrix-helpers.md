Below are the excerpts from the design doc for the general helpers, and some matrix specific ones.


There are also load-tile, store-tile, convert-layout and others, but I think we'll hold off on them.
load-tile and store-tile should probably be redesigned to accomodate asynchronous operations, 
and convert-layout needs a LOT more infra until it can be realized.  





Helper Functions
(element-type~ someStorageHandle) a type expression that returns the type of the elements in the Storage Handle.

(bytes~ someStorageHandle) a helper function that calculates the current number of bytes in the Storage Handle. Note that this is NOT a passthrough. If you want the total number of bytes in the parent storage you’ll need (byte-size~ (parent~ someStorageHandle))

(num-dims-of someStorageHandle) returns the number of dimensions of a storage handle. Very useful for the tensor type, less so for the others.


---

Matrices
(def-type matrix (tensor T 2))

Matrices are simply 2D tensor views. The type alias matrix is defined to make coding easier, but any 2D tensor can automatically be considered a matrix. It is not a “derived” type.

Additionally, there are special functions specifically for matrices.

col
(col x:ulong A:matrix) => 1D tensor

Given an index x and a 2D tensor matrix A this returns a 1D tensor of that column of the matrix.

row
(row y:ulong A:matrix) => 1D tensor

Given an index y and a 2D tensor matrix A this returns a 1D tensor of that row of the matrix.

num-cols / num-rows
(num-cols A:matrix) => ulong (num-rows A:matrix) => ulong

These utility functions return the number of columns or rows of the matrix.

get-layout
(get-layout M:matrix) => :row-major or :col-major or :other-layout
get-layout analyses the strides of some 2D matrix and returns a value from the matrix-layout enumeration. This can be :row-major, :col-major or :other-layout

transpose
(transpose M) ; returns a new tensor, leaving M alone.
(transpose! M) ; M is transposed, strides updated in place
The transpose operations swap the logical “shape” of the matrix. For example, starting with a 3x4 matrix and ending with a 4x3 matrix. This is done simply by updating the strides. It is instant and zero cost.

Note that the while data is not moved it does mean that a “row major” matrix will now be “col major”, and vice versa

---