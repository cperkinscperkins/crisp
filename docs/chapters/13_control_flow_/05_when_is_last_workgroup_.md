# when-is-last-workgroup 📝

`when-is-last-workgroup` captures the "last block standing" pattern. It provides a mechanism to elect a single workgroup to perform a final action after all other workgroups have completed their primary tasks up to that point. It does not cause other workgroups to wait. You can think of the other workgroups as party guests that continue on home, leaving the last one to whatever work is in the block.

It uses an internal atomic counter to determine which workgroup is the last to arrive at this point in the kernel. The body of the `when-is-last-workgroup` is then executed only by the threads within that single, elected workgroup. This is useful for performing a final, small reduction or cleanup step on data that has been prepared by all workgroups.
When it reaches the last workgroup, then the body of `when-is-last-workgroup` begins.   

```
(when-is-last-workgroup () ...)
(when-is-last-workgroup (id) ...)
(when-is-last-workgroup (x-id y-id) ...)
(when-is-last-workgroup (x-id y-id z-id) ...)
```

Example:
```
 ; lots of things being done by many threads and workgroups
 (when-is-last-workgroup (wg-id)
   ; now continue, knowing that "lots of things" are done everywhere.
   ...)
```

Implementation Notes
```
;; initialize *internal-global-counter* to (get-num-groups).  MUST BE :GLOBAL memory
;; initialize old-count to 0 .  MUST BE :local MEMORY
;; (declare (grid-level))

; start when-is-last-workgroup
;; Executed by thread 0 of each workgroup
(mem-fence :global)
(local-barrier)
(when-thread-in-group-is 0
   (set! old-count (atomic-dec! *internal-global-counter*))
   (local-barrier))

(when (= old-count 1)
    ;; body of when-is-last-workgroup
    )
```

