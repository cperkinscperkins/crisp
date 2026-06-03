# Element Access ✅


- `~`
- `~ref~`

`~` is the main function for accessing elements in a Storage Handle. It can be `set!` and overloaded.
It would be supremely unwise to overload `~` generally. Instead use `def-derived-type` to 
define your own subtype and overload `~` for that type. 

```
;; cell
(~ <cell>) ;; get
(set! (~ <cell>) <value>) ;; to  set!

;; vector
(~ <vector> <index>) ;; to get 
(set! (~ <vector> <index>) <value>) ;; to set!

;; soa-vector of point
(x~ <soa-vec> <index>) ;; get the `x` of point at <index>
(set! (x~ <soa-vec> <index>)  <someValue>) ;; set the `x` of the point at <index>

;; matrix
(~ <matrix> <y-index> <x-index>) ;; to get
(set! (~ <matrix> <y-index> <x-index>)  <someValue>) ;; to set!

;; tensor
(~ <tensor> ... <z-index> <y-index> <x-index>) ;; get
(set~ (~ <tensor> ... <z-index> <y-index> <x-index>) <someValue>)
```

```
; example
(let ((vec #(2 4 6 8))
      (elem (~ vec 1))) ;; 4
  (set! (~ vec 0) (* 2 elem))) ;; stores "8" into the first position of the vec.
```

#### `~ref~` ✅ 
 `~ref~` can also be used to get and set elements in a Storage Handle and these element
access functions cannot be overloaded.   `~ref~` is intended to be used from overloads of `~`

```
;; example with vector
(~ref~ <vector> <index>)  
(set! (~ref~ <vector> <index>) <value>)
```


