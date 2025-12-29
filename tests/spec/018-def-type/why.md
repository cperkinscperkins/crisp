
I was considering implementing def-type:
@19_type_aliases_and_type_constructors.md   

It is used throughout the document. It makes aliases from one type to another, that's pretty trivial ( def-type i int )

But it can also be used to make short-hand type constructors from existing ones. Now, the only things in Crisp that even have type constructors are structs, records, and the Storage Handle types (cell, vector, matrix, tensor) by virtue that they are all derived from records. 

A regular record just has a key based type constructor, with keys for the compile-time properties.  Of course, they can be templated, and then you get the template type args AND the compile-time property keys.  
The Storage Handles do one better and use the that last combination (cell T :address-space  _ :access _), but they also have an &optional variant.  We have that in cell
(cell T  &optional  address-space access) .  Tis confusing.

One of the main uses of def-type is to make shorthand Storage Handle constructors.   
(<T>
(def-type in-cell (cell T :address-space :global :access :readable)))

or
(<T>
 (def-type scratch-cell (cell T :address-space :local :access :read-write)))

Those things are VERY handy:  
(<T>
(def-function foo (in out &optional (scratch-mem (make-scratch-cell T :name "bar")))
  (declare #'((in-cell T) (out-cell T) &optional (scratch-cell T) => nil)) ...))



And, for us, one of the important uses of def-type is to first define tensor and then use def-type to define matrix as a tensor arity 2, and vector as a tensor arity 1.  And done.  