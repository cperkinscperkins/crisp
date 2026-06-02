# element-wise access ✅


Element-wise access to microfloat blocks is not slow (like atomic ops or reading global memory). 
But it is not optimal.  Try to avoid element-wise block access if possible. 

#### `~`

`(~ MFB index) => base` 
The `~` array access expression can be used to access the raw unscaled base value of any microfloat block.

#### `to-float`

`(to-float MFB index) => float`
An override of `to-float` exists that can take microfloat block argument and an index. It will retrieve 
the microfloat type at that index, scale it appropriately, and then return "regular" `float` type. 



