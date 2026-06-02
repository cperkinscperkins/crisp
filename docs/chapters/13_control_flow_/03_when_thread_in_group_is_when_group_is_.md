# when-thread-in-group-is / when-group-is ✅


`when-thread-in-group-is` is much like `when-thread-is` except that instead of using the global thread id,
the local id is used instead.  In other words, there is an implicit `(when (= someId (get-local-id 0)) ...)`

Similarly, `when-group-is` is akin to those except that the group id is used instead.  In other words, there is an implicit `(when (= someId (get-group-id 0)) ...)`

```
(when-thread-in-group-is id <expr>)
(when-thread-in-group-is x-id y-id  <expr>)        
(when-thread-in-group-is x-id y-id z-id <expr>)   

(when-group-is id <expr>)
(when-group-is x-id y-id  <expr>)        
(when-group-is x-id y-id z-id <expr>)   
```

### local-barrier compilation issue.

Using `(local-barrier)` inside the scope of `when-thread-in-group-is` results in a compilation error as it would otherwise deadlock an entire workgroup.

Crisp users are strongly encouraged to use `when-thread-in-group-is` as opposed to a generic construction like  `(when (= (get-local-id) 0) ...)`  for this reason. The compiler will _attempt_ to detect the deadlock possibility in a generic construction, but due to variables, assignments, etc that guarantee is not strong. Whereas in `when-thread-in-group-is` it is a surety.

