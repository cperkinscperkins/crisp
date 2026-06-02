# Predicated Selection ✅


Because the cost of branch divergence is so high, it is often just preferable to evaluate BOTH the consequent and alternative and
select the correct one in response to a predicate. That what `select-if` is for. Use it with simple values for `<expr-A>` and `<expr-B>` 
and you'll be fine. 

`(let ((v (select-if <predicate-expr> <expr-A> <expr-B>))))  ; BOTH expr-A and expr-B will be evaluated/executed. `

This does NOT have shortcut evaluation like in C++.  Recommend that `<expr-A>` and `<expr-B>` be simple.

There is no uniform `+` or `*` variant for `select-if`.

<!-- NOTE: how is this actually realized on a GPU -->


