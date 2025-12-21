# Assist defmacro Development


Crisp has some constructs that are useful to developers leveraging `defmacro` and needing
to navigate the Crisp-specific terrain.

### `is-thread-level?`

`(is-thread-level? function-identifier) => T/nil`

`is-thread-level?` is a compile time introspection function that can help write certain types of macros.  It returns
`T` if the function in question was defined with `def-function` and `nil` for anything else.

Usage Example
```
(defmacro process-vector (vec func)
  ;; Check if 'func' is a simple, thread-level function
  (if (is-thread-level? func)
      ;; If YES: Wrap it in a grid-level primitive
      `(map-stride ,func ,vec ,vec)
      
      ;; If NO: It must be a def-grid-function, so just call it
      `(,func ,vec)))
```

### `get-return-type`

`(get-return-type function-identifier) => <Type>`

`get-return-type` is a compile time introspection function for macro writing. It returns the return type of the 
function in question. This is NOT the same as `return-type-of` which is a type expression meant to be used in 
a type declaration.  

Remember that Crisp types are NOT available at runtime. 

Example
```
(defmacro some-HOF-op (func A B &out C)
  ;; do some compile time checking
  (let ((ResultType (get-return-type func)))
    ;; 4. Check if the output vector 'C' matches.
    (c-t-assert (type-equal (element-type C) ResultType) "Output vector C has wrong type")
    ...
```

### `get-signature`

`(get-signature function-identifier)` => <Signature>`

```
(get-signature #'int_vector_sum) =>  `((vector int :std140 :global :readable) &out (vector int :std140 :global :write_only))
```


### `can-call?`

`(can-call? function-identifier &rest argument-types) => T/nil`

`can-call?` is another compile time introspection construct for macro writers. With it you 
can determine if some function is "callable" with some set of argument types. 

Example:
```
(can-call? #'+ 'int 'float) =>  T 

(can-call? #'* 'int 'point) => nil
```

### `get-struct-members`

`(get-struct-members 'point) => '(x y)`

This is a low-level introspection macro useful for writing other macros (such as `with-struct-accessors`)
For some named struct type it returns a list of property name symbols. 

Example (Reminder: this is all compile-time evaluated code from a macro, not runtime code in any Crisp top level execution context)
```
(let ((member-count (length (get-struct-members 'my-struct))))
  ...)
;; OR
(when (member 'energy (get-struct-members 'particle-struct))
  ...)
```

### `get-struct-types`

`(get-struct-types 'point) => '(float float)`

Another low-level introspection macro. For the named struct it returns a list of type expressions.

### `get-c-t-length`

`(get-c-t-length <vector-or-tensor-type>) => length or nil`

`get-c-t-length` is passed a vector type and will return its length if it is known at compile time.
Otherwise it returns nil.  Can be used for various purposes, including making unrolling decisions.

### `get-current-context`

`(get-curret-context) => :dispatch / :grid / :thread`

Returns the context at the place where the macro is called. Useful if you need to write macros
that alter behavior based on context in order to provide a predictable experience for the caller.


### `is-logging?`

`(is-logging?) => T or nil`

Returns true if the file is being compiled with the `--logging-output` flag 

### `is-runtime-checking?`
`(is-runtime-checking?) => T or nil`

Returns true if the file is being compiled with the `--runtime-checks` flag


### `(declare (grid-level))`

This was mentioned earlier, under  [Grid Level Operations](#grid-level-operations)
A macro can add this declaration to a `progn` when doing grid level ops, and then the compiler
will ensure the proper call context restrictions are observed.

### `(declare (warp-convergent))` and `(declare (workgroup-convergent))`


The `(declare (XXXX-convergent))` tag is a safety contract between your new macro and the Crisp compiler's static analyzer.
When you add this declaration, you are "tagging" your macro and telling the compiler:
> "This code block MUST be called by all threads in its group (warp or workgroup) to avoid a deadlock. You (the compiler) are now responsible for ensuring this rule is followed."

This tag enables Crisp's `(check-divergence)` static analysis. The compiler will then throw a compile-time error if an end-user tries to call your macro from inside a divergent branch (like a `(when (< (get-local-id 0) 10) ...)`).

Many constructs in Crisp, like `local-barrier` or shuffle operations, automatically inject the appropriate "taint", 
so you don't need this declaration when those are present. But it is easy to write a macro that _assumes_ warp or workgroup wide operation. In that case, use the declaration so the compiler will help users of your macro. 

