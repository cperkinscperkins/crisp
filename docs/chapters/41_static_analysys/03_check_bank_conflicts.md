## check-bank-conflicts


```
;; in a kernel or function progn:
(declare (check-bank-conflicts))

;; top level of file
(declaim (check-bank-conflicts #'some-function))
```

Local/shared memory is divided into a number of parallel memory banks (typically 32). 
Performance is highest when threads in a warp access different banks. If multiple threads
in a warp access the same bank simultaneously, it's a bank conflict, and the
accesses are serialized, killing performance.

When this check is enabled, the compiler analyzes all access to `:local` vectors. 
It looks at the index calculation for each thread within a warp. If it can prove that multiple
threads are accessing memory with a stride that is a multiple of the bank count 
(e.g., thread i accesses local_array[i * 32]), it issues a warning.  It will emit a note if it 
the analysis completes and no conflicts are found.


