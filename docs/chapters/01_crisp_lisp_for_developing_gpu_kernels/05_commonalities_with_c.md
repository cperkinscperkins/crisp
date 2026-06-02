## Commonalities with C++


### Monomorphization
Monomorphization is just a big word for "templates". Look it up.

### Static Typing

The Crisp basic types are the same as in C++. The type promotion rules differ though.

### Zero Cost Abstractions

Did you know that C++ `std::sort` is faster than quicksort because it inlines the comparator?
Crisp does that sort of thing too, except there is no `std::sort`.

### SFINAE

Just kidding. Crisp doesn't do SFINAE. It has Common Lisp `defmacro` which is better++.




