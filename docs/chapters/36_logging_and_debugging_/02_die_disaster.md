# `(die "disaster")`


```
(when (< index 0))
  (die "the index is negative? How did that happen?"))   ;; desperate times
```

`die` is a small but critical component. If `--logging-output` was NOT elected, then 
`die` simply halts the kernel.  
But if the kernel is debugging output then its message is recorded into the debug output buffer 
and then the kernel is halted. 
Note that the message argument to `die` must be known at compile time.

Importantly, space is ALWAYS reserved in the output buffer for the `die` message.

`die` records a tiny 16 byte record (per workgroup) into global memory
and then halts the kenrel. It is up to the host side caller to retreive that data and 
check it. The 16 bytes don't contain any text message like the one above, instead it
has a numeric identifier which can be looked up in either the metadata or the hoisting code
to see the original string.  The 16 bytes record 
- string_id
- file_id
- line_no
- local_id x, y, z



Possible Implementation
```
(defmacro (die msg-string)
  
  ;; compiler packs all the data at compile-time
  (let* ((my-string-id (get-compiler-id-for msg-string))
         (my-file-id (get-compiler-id-for (file)))
         (my-line-no (line))
         
         ;; pack the primary 64-bit "flag"
         (my-primary-data (pack-u64 my-string-id my-file-id my-line-no))
        
         ;; get my workgroup's slot in the global "die" buffer
         (my-wg-id (get-workgroup-id))
         (my-die-slot-address (~ die-buffer my-wg-id)) ;; 'die-buffer' captured non-hygenically
         (primary-field-address (& (~ my-die-slot-address 'primary))))  ;: & 
        
    
    ;; try to claim the slot.
    ;;    (cas address, expected_value, new_value)
    (let ((old-val (atomic-cas! primary-field-address 0 my-primary-data))
          (old-val (atmoic-binop! primary-field-address (ident my-primary-data) 0)))
      
      ;; check if I won the race
      (when (= old-val 0)
        ;; I WON! I am the first thread to die in this WG.
        ;; Now I safely write the *secondary* data.
        (let* ((my-local-x (get-local-id 0))
               (my-local-y (get-local-id 1))
               (my-local-z (get-local-id 2))
               (my-secondary-data (pack-u64 my-local-x my-local-y my-local-z 0))
               (secondary-field-address (& (~ my-die-slot-address 'secondary))))
          (set! (~ secondary-field-address) my-secondary-data))))
        
    ;; regardless of if I won or not, I must halt.
    (device-halt!)))
```

