# C API 📝


<!-- NOTE  Let's rename "tree shaking" throughout. set_cache_directory() ??  But also change the flag -->

#### `new_context( target_identifier )`   📝 
    
`target_identifier` is one ID from either IR or binary target flags.
returns a pointer to a context.

#### `set_tree_shake_directory( context, path )` 📝

`path` is null terminated C string.

if the `--tree-shaking` compilation was performed earlier, then its output directory can be 
used as the input tree_shake directory for the in-memory compiler. This can 
greatly speed up in-memory compilation.

The relevant flags used (and recorded) in that compilation will be used. 
See the section on `flags` below.

#### `add_input_file( context, file.crisp )` 📝

Reads in the file and adds the crisp source to the context.  Returns an error if the file could not be read.

#### `add_input_string ( context, crisp_string, virtual_file_name )` 📝

Adds the crisp source to the context. The `virtual_file_name` (e.g. "my_dynamic_kernel.crisp")
can help make compilation error messages more understandable.


#### `set_flags( context, string )` 📝

This is a just a string of flags and values like you would submit
to the crisp.exe compiler. If using `set_tree_shake_director()` then
this call is likely not needed .  See the section on `flags` below. 

Example:
```
  set_flags(ctx, "-DMAX_INDEX=40 --single-pass --no-inference");
```
#### `get_flags( context, char** flagHandle, size_t* sz )` 📝


If using `set_tree_shake_director()` then this populates the flagHandle with the flags
passed when the tree shaking was performed. Otherwise it returns nothing.

Call with nullptr for `flagHandle` to have the `sz` set to the size needed, then
call again with both set.

#### `compile(context, size_t* sz)` 📝

compiles everything. If this is the first call and `set_tree_shake_directory( path )` was 
called earlier then there may be file I/O as the files from the tree shaking get read in.

returns a status code. If successful `sz` will be set to the size of the binary.
See "Status Codes" below.

#### `compile( context,  string, size_t* sz )` 📝

adds string to the context and compiles everything. If the string has definitions
that have the same name as others that were loaded into the context earlier, 
it does not trigger an error. Instead, any definitions in string are presumed to override.

returns a status code. If successful `sz` will be set to the size of the binary.
See "Status Codes" below.


#### `bool get_binary(context, const void** out_data, size_t* out_size)` 📝

Gets the size and a pointer to the compiled binary from the last successful compilation.
return true on success, false if no binary is available.

The binary/ir result of the compilation. Something that can be passed 
to `clCreateProgramWithBinary` or its equivalent.

#### `long get_compilation_error_code(context)` 📝

Retrieve the actual compilation error code from the last compilation attempt. 0 if successful.

#### `const char* get_messages(context)` 📝

Gets any error or warning messages from the last compilation attempt (successful or not).

#### `const char* get_metadata(context)` 📝

Gets the metadata from the last successful compilation. Format TBD.

#### `destroy_context( context )` 📝

Destroys the context. 

