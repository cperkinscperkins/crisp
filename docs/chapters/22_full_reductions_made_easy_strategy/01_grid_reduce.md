# `grid-reduce!` ✅

```
(grid-reduce! someFunction <someVar> identity return-cell
              &key strategy message
                   local-scratch-vec global-scratch-vec atomic-counter election-flag-cell)
```

`grid-reduce!` performs a `reduce-workgroup` on `<someVar>` as Phase 1, then uses `:strategy` for Phase 2, storing the final value in `return-cell`:

* `:strategy` is one of `:atomic`, `:cas` or `:last-man-standing`, and defaults to `:last-man-standing`. It must be written as a literal keyword, because it decides which construct the call becomes (`grid-reduce-atomic!`, `grid-reduce-cas!` or `grid-reduce-last-man!`); a value computed at run time is a compilation error. There is no second-stage strategy: that needs a second kernel launch, which one call cannot arrange -- use `grid-reduce-second-stage!` in the second kernel.
* The default carries last-man's limit: the number of workgroups must not exceed `local_work_size`.
* `return-cell` is a `cell` of `<someVar>`'s type (a length-1 vector is also accepted). `:atomic` and `:cas` *accumulate* into it, so it should start at the identity; `:last-man-standing` *writes* it.
* Every scratch argument is optional and is allocated by Crisp when left out, typed from the identity (see the condition above). A scratch key the chosen strategy does not use is a compilation error: `:atomic` and `:cas` take only `:local-scratch-vec`.
* `:atomic` still requires an operator with a native hardware atomic (`#'+`, `#'min`, `#'max`).
* Autodiff works through `grid-reduce!`: it becomes one of the three constructs above, each of which has its own VJP.

```
(grid-reduce! #'+ sumF 0.0f float-c :strategy :cas :message "gridwise reduction of sumF")
```






