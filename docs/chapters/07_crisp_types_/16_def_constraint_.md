# def-constraint 📝


Constraint functions are not regular functions. They are limited to where they can
be invoked and must be fully evaluable at compile time. All constraint functions 
have the same signature and do not need to declare it. Every constraint function
takes a single type as an argument and returns a boolean. 

They cannot perform other actions, like generating specializations or defining new types etc.
If it is C++ SFINAE-like support you seek, check out `defmacro` and the
section on "Conditional Compilation". 

Example:

```
(def-constraint has-energy? (T)
  (type-has-prop? T 'energy))


(def-constraint is-comparable? (T)
  (and (has-overload? #'< #(T T => bool))
       (has-overload? #'> #(T T => bool))))
```

Constraint functions are primarily used in conjuction with `with-template-type`.  
See the sub-section on "type constraints" above.

Crisp has some functions that can help you define your own type constraints:

### type-has-prop?

`(type-has-prop? someType propName)`

evaluates to T/nil if something of someType has a member with that name, accessible
with `(<propName>~ obj)`
e.g.  `(type-has-prop? T 'length)` 


### has-overload?

`(has-overload? someF someSignature)`

evaluates to T/nil if a particular function has an overload of the provided signature.

e.g. `(has-overload? #'+ #(float float => float))`

### is-substitutable-for?

`(is-substitutable-for? substT baseT)`

The `is-XXXX?` types constraint functions are exact. If using derived types, 
flexibility might be desired. `is-substitutable-for?` returns True if the type `substT` 
can be substituted for the type `baseT`. The substitution follows the `:subst` key 
when derived types are used.

```
(def-struct point ...)
(def-derived-type coordinate point :subst :pass-derived)

(is-substitutable-for? coordinate point) ;  => True ( because :pass-derived)
(is-substitutable-for? point coordinate) ;  => False.
```

| `:subst`        | `(is-substitutable-for? derived-T original-T)` | `(is-substitutable-for? original-T derived-T)` |
|-----------------|------------------------------------------------|------------------------------------------------|
| `:no`           |  `nil`                                         | `nil`                                          |
| `:equal`        |  `T`                                           | `T`                                            |
| `:pass-derived` |  `T`                                           | `nil`                                          |
| `:pass-orig`    |  `nil`                                         | `T`                                            |


