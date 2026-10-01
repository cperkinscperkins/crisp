# Semaphore Operations 📝

```
(make-semaphore :address-space :global/:local :initial-value <int> :scope :system/:device) => sema
(semaphore-release sema new-value)
(semaphore-acquire sema expected-value)

;; semaphore type declaration:
(semaphore :address-space <as> :scope <s>)
;; :scope defaults to :device.
;; :address-space must be provided for a complete type definition (as would be required at the kernel boundary).
```

Semaphore is just a location in :global or :local address space.  Must be enqueued by the host.  
Crisp will need a semaphore data type. (and a marshall- routine)

`make-semaphore` for :global has to do the "side channel" thing. Gets implicitly added to the kernel arglist. 

`make-semaphore` for :local must be prepared by host, BUT can be "carved out" of kernel space since it is a known fixed size.
Obviously, we can't do 'make-semaphore` in a loop etc.  

#### make-semaphore
`(make-semaphore &key address-space initial-value (scope :device)) => sema`

For semaphores used within the same kernel call, it is only necessary to set `:address-space` to `:local`.
If a semaphore is used between kernel calls, then the `:address-space` should be `:global`.

For interoperating with Vulkan, OpenGL, or CPU-side code, the `:scope` must be set to `:system`.
If interoperating with other kernels but in the same execution context, then the `:scope` should be `:device`.

