# def-parameter 📝


`def-parameter` is used to define the type and possible default value for parameters that might 
come in from the compiler when it is invoked.   `def-parameter` is very similar to `def-const` in
that it also defines an immutable expression in global file scope.
`(def-parameter <parameter-name> &optional <default-value> <type>)`

Like in C++, the `-D` flag is used to specify a parameter and is followed by the parameter name, equal sign and a value without spaces.
e.g. `-DMAX_INDEX=40` 

Paramter names should follow the C standard identifying rules. (ie use underscores, not dashes)

**NOTE:** Parameter names, like kernel names, are _case sensitive_, unlike other names in Crisp.


```
;; in the .crisp file
(def-parameter MAX_INDEX 100 ulong) ;; 100 is default value, used when not provided by the compiler invocation.

(def-parameter START_LOC 41.1)
(declaim (type START_LOC float))



# the compiler invocation
crisp.exe -DMAX_INDEX=35  my_kernels.crisp
```

<!-- NOTE: def-const supports type inference, should def-parameter.  Why not?
    
    NOTE: what about + on both sides?  Plus sign can be interpreted differently by shells, so best to avoid it 
          appearing on any command line.  We could auto add it?  (def-parameter +X+ ..)  / crisp -DX=4
          Meh, seems brittle and weird. 
-->



