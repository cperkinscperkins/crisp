# Other Basic Types ⚠️


> NOTE: this section needs work

#### bool    
- `bool` is a type
- its values are `true` and `false`
- any zero number value puns as `false`
- any non-zero number value puns as `true`
- `nil` is a compile-time expression (not runtime). It also puns as `false`.
- an instance of any other Crisp type (struct, vector, etc) puns as `true`.

Currently under debate whether `bool` is an instantiable value.


#### symbols

Common Lisp has a symbol type and it is repelete with them. Crisp does not support these
in the runtime. Note that the only known implementation of Crips uses Common Lisp 
for macro evaluation. And, so, in that context, symbols are allowed.

You'll also see that types are passed to macros, they are usually quoted like symbols (`'int`).

But as a general rule, symbols are not support in Crisp and the compiler will error if you
try to use them in runtime code. See `keyword symbols` below for the exception to this rule.

#### keyword symbols

keyword symbols (`:some-key` ) ARE supported, but are only usable as values if
they appear in an enumartion. 
(Note, they don't need to be in an enumeration if they are simply function parameter keys)

                            
#### higher order functions
`#'someFunction` are supported. But must be compile-time determinable.  See [Higher Order Functions](#higher-order-function-operations)



