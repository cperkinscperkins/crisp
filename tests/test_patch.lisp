(:file "tests/patch_test_target.lisp"
       :search "(defun goodbye ()
    (print \"Goodbye\"))"
       :replace "(defun goodbye ()
  (print \"Goodbye Cruel World\"))")
