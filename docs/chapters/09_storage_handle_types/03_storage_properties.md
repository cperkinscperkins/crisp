# Storage Properties ✅


 `storage` has the following immutable properties:

| Property      | Type          |              |     Description |
| --------------|---------------|--------------|-----------------|
| byte-size~         | ulong         | runtime      | the number of bytes in the `storage`. This is immutable.|
| base-ptr~     | voidp          | runtime      | the voidp pointer of the storage. |
| address-space~ | address-space | compile-time | one of `:global`, `:local`, `:constant` |



The `byte-size~` property for a `storage` is sometimes known at compile time, but is most often a runtime property.  The `base-ptr~` is most definitely a runtime property. 
However the other properties are all known and evaluable at compile time. 

<!-- IMPLEMENTATION NOTE:

We should be able to model storage as a def-record.  But note that the memory address the storage is tracking is both a runtime property AND not directly 
accessible to the user. 

BUT - at the moment, let's NOT hide "address" from the user.  We'll simply
not document it, and play it by ear later. 

;; the address-space enumerations provide the "type" for the
;; storage properties of the same name. 

(def-record storage
    (address ulong)    
    (byte-size ulong)
    (address-space address-space :c-t))

-->

