

;; DEMONSTRATION


(def-struct server
  ;; Define 'token-t' as a unique brand tied to instances of this struct.
  ;; It is backed by a ulong (64-bit int).
  (brand token-t ulong :subst :no :enforce :always)
  
  ;; property that uses this brand.
  ;; value stored here is "stamped" with the instance's brand.
  (active-token token-t)
  (id int))

;; function with dependent signature
(def-function authenticate (s tok)
  ;; CRITICAL: The type of the 2nd argument depends on the 1st argument.
  ;; It requires 'tok' to be a token specifically belonging to 's'.
  (declare #'(server (token-t s) => int))
  
  ;; implementation is irrelevant for the type check
  1)

(def-function happy-path ()
    (declare (return-type nil))
  (let ((s1 (make-server :active-token 12345 :id 1)))
    
    ;; extract the token from s1. 
    ;; compiler should type this variable as: (token-t s1)
    (let ((my-token (active-token~ s1)))
      
      ;; pass s1 and my-token to authenticate.
      ;; signature match: server vs server, (token-t s1) vs (token-t s1).
      (authenticate s1 my-token))))

(def-function compilation-error ()
  (declare (return-type nil))
  (let ((s1 (make-server :active-token 11111 :id 1))
        (s2 (make-server :active-token 22222 :id 2)))
    
    ;; take the token from s2. type is: (token-t s2)
    (let ((stolen-token (active-token~ s2)))
      
      ;; try to use s2's token to authenticate with s1.
      ;; function expects: (token-t s1)
      ;; we are passing:   (token-t s2)
      ;; EXPECT COMPILATION ERROR - some sort of type mismatch, 
      (authenticate s1 stolen-token))))

(def-function also-compilation-error ()
  (let ((s1 (make-server :active-token 12345 :id 1)))
    
    ;; try to pass a raw number (12345) to the function.
    ;; function expects: (token-t s1)
    ;; we are passing:   ulong
    ;; another compilation ERROR
    (authenticate s1 12345)))

(def-function arithmetic-safety ()
  (let ((s1 (make-server :active-token 10 :id 1))
        (s2 (make-server :active-token 20 :id 2)))

    (let ((t1 (active-token~ s1))
          (t2 (active-token~ s1))  ;; same instance as t1
          (t3 (active-token~ s2))) ;; different instance
      
      ;; same-instance math should be valid
      ;; (token-t s1) + (token-t s1) => (token-t s1)
      (assert-equal (as-ulong (+ t1 t2)) 30) ;; no good way to assert. 

      ;; cross-instance math should fail
      ;; (token-t s1) + (token-t s2) => ???
      ;; EXPECT COMPILATION ERROR: "Cannot mix branded types from different instances"
      (+ t1 t3))))