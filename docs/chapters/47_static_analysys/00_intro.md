# Static Analysys 📝


> The minute you finally understand how a GPU works is the minute you are wrong.
>
> — John Owens, UC Davis

If you were ever wondering why Crisp is intentionally not Turing-complete, this section is the answer. 
Because every kernel is guaranteed to terminate, its control flow is finite and can be completely analyzed by the compiler. 
This allows Crisp to sidestep the Halting Problem, unlocking a suite of deep static analysis tools 
that would be impossible to implement reliably in a general-purpose language.

To help programmers reach full GPU performance and avoid errors, Crisp includes some static analysis ability. 
It makes little sense to apply these globally, as that would result in a lot of false positive warnings. 
Therefore the Crisp static analysis is "opt-in".

These opt-in analysis will slow down the compilation. Use the `--no-static-analysis` compiler flag to skip them.

Note, also, that the static analysis usually requires two pass compilation. If you elect `--single-pass` they are likely
skipped. The compiler will warn you if it is skipping any.  Don't rely on `--single-pass` to skip them. 
If you have static analysis opt-ins within your file, 
and you don't want that analysis performed, use `--no-static-analysis`. 

