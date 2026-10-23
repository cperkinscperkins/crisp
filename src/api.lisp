;;; src/api.lisp -- Endeavour 190: the Lisp core behind the C compile API (c-api/include/crisp.h).
;;;
;;; COMPILE-SOURCES takes Crisp source STRINGS, flags and ONE target and returns everything the C
;;; side hands out, as a plain nested plist (shape documented on COMPILE-SOURCES).  It is the
;;; in-image half of the out-of-process design (A1): the server reads a request, calls this, and
;;; writes the result back.
;;;
;;; It reuses the CLI's own helpers (%read-crisp-forms, %emit-target-output, %generate-file-metadata
;;; ...) by writing each source into a private temp directory, so the API and crisp-compile run the
;;; SAME compile path.  What it must never do, unlike compile-files / parse-cli-args:
;;;   - quit the image (every failure is a STATUS plus diagnostics),
;;;   - write to *standard-output* (the server's protocol channel),
;;;   - leave files behind.
;;; Kernel facts come from the .metacrisp the compile writes (D7: .metacrisp is THE metadata),
;;; read back with *read-eval* off into a private package.

(in-package :crisp.main)

(defvar *api-temp-root* nil
  "Directory under which COMPILE-SOURCES makes one private temp directory per compile.  NIL means
   <system temp>/crisp-api/.  Tests rebind it so 'no files left behind' is checkable.")

(defvar *api-temp-counter* 0
  "Makes temp directory names unique within this image (a random part makes them unique across images).")

(defvar *api-random-state* nil
  "Seeded on first use, at RUN time: a saved image's default random state is identical in every
   process started from it, so two compile servers would otherwise pick the same temp names.")

;;; ------------------------------------------------------------------------------------------------
;;; Flags
;;; ------------------------------------------------------------------------------------------------

(defparameter +api-rejected-flag-prefixes+
  '(("--hoist" . "hoisting is not available through the compile API")
    ("--metadata" . "metadata is always produced by the compile API; query it instead")
    ("--ir-target=" . "the target is fixed when the context is created")
    ("--log-level=" . "compiler logging cannot go to the API's output channel"))
  "Flags the compile API refuses, with the reason.  Matched as prefixes.")

(defparameter +api-choice-flags+
  '(("--math-precision=" :math-precision (("ieee" . :ieee) ("fast" . :fast)))
    ("--force-math-precision=" :force-math-precision (("ieee" . :ieee) ("fast" . :fast)))
    ("--denormal-handling=" :denormal-handling (("ftz" . :ftz) ("preserve" . :preserve))))
  "Valued flags with a fixed set of spellings: (PREFIX SETTING-KEY CHOICES).")

(defparameter +api-free-value-flags+
  '(("--hardware-profile=" :hardware-profile)
    ("--ir-target-arch=" :ir-target-arch))
  "Valued flags whose value is checked later by the compiler itself: (PREFIX SETTING-KEY).")

(defparameter +api-boolean-flags+
  '(("--debug" :debug) ("-g" :debug) ("--single-pass" :single-pass)
    ("--runtime-checks" :runtime-checks) ("--differentiate" :differentiate))
  "Flags that switch something on: (FLAG SETTING-KEY).")

(defun %api-parse-flags (flags)
  "FLAGS (a list of strings, as crisp-compile takes them) as a settings plist.
   Returns (values SETTINGS NIL) or (values NIL MESSAGE) -- MESSAGE names the offending flag.
   Unknown flags are REJECTED (the CLI ignores them; an API caller deserves to hear about a typo)."
  (let ((settings (list :math-precision :ieee :force-math-precision nil :denormal-handling :preserve)))
    (dolist (flag flags)
      (let ((rejected (find-if (lambda (r) (alexandria:starts-with-subseq (car r) flag))
                               +api-rejected-flag-prefixes+))
            (choice (find-if (lambda (c) (alexandria:starts-with-subseq (first c) flag)) +api-choice-flags+))
            (free (find-if (lambda (c) (alexandria:starts-with-subseq (first c) flag)) +api-free-value-flags+))
            (bool (find flag +api-boolean-flags+ :key #'first :test #'string=)))
        (cond
          (rejected
           (return-from %api-parse-flags
             (values nil (format nil "flag ~a is not accepted: ~a" flag (cdr rejected)))))
          (choice
           (destructuring-bind (prefix key choices) choice
             (let* ((value (subseq flag (length prefix)))
                    (kw (cdr (assoc value choices :test #'string-equal))))
               (unless kw
                 (return-from %api-parse-flags
                   (values nil (format nil "flag ~a: unknown value '~a' (expected ~{~a~^|~})"
                                       flag value (mapcar #'car choices)))))
               (setf (getf settings key) kw)
               ;; remembered so the fast-vs-preserve warning fires only on an EXPLICIT preserve
               (when (eq key :denormal-handling) (setf (getf settings :denormal-explicit) t)))))
          (free
           (destructuring-bind (prefix key) free
             (let ((value (subseq flag (length prefix))))
               (when (zerop (length value))
                 (return-from %api-parse-flags (values nil (format nil "flag ~a needs a value" flag))))
               (setf (getf settings key) value))))
          (bool (setf (getf settings (second bool)) t))
          (t (return-from %api-parse-flags (values nil (format nil "unknown flag ~a" flag)))))))
    (log:debug "compile API flags ~s -> ~s" flags settings)
    (values settings nil)))

(defun %api-parse-target (target)
  "TARGET (\"spv\", \"spirv\" or \"ptx\", any case) as a backend keyword, or NIL if unknown."
  (cond ((null target) nil)
        ((member target '("spv" "spirv") :test #'string-equal) :spirv)
        ((string-equal target "ptx") :ptx)))

(defun %api-flag-warnings (settings)
  "The warnings crisp-compile prints for SETTINGS (parse-cli-args), as diagnostics.
   One deliberate difference: the fast-vs-preserve warning needs an EXPLICIT --denormal-handling=preserve.
   parse-cli-args warns whenever precision is fast, because :preserve is merely the default there."
  (let ((out nil))
    (when (getf settings :force-math-precision)
      (push (%api-diagnostic :warning "--force-math-precision overrides all in-source precision choices; use for testing/validation only.") out))
    (when (and (eq (or (getf settings :force-math-precision) (getf settings :math-precision)) :fast)
               (eq (getf settings :denormal-handling) :preserve)
               (getf settings :denormal-explicit))
      (push (%api-diagnostic :warning "`fast` precision flushes denormals; the `preserve` request is not honored under `fast` -- use `ieee` if you need denormal preservation.") out))
    (nreverse out)))

;;; ------------------------------------------------------------------------------------------------
;;; Diagnostics
;;; ------------------------------------------------------------------------------------------------

(defun %api-diagnostic (severity message &key file (line 0) (column 0))
  "One diagnostic plist.  LINE / COLUMN are 1-based, 0 when unknown -- always 0 today: Crisp locates
   errors by form path, not by line (TODO(190))."
  (list :severity severity :message message :file file :line line :column column))

(defun %api-condition-message (c)
  "C's report as one string, with its source location (a form path) when it has one -- the same text
   print-compiler-error writes, without the 'Crisp compilation failed in' header."
  (let ((*print-right-margin* 100000))
    (string-trim '(#\Space #\Newline #\Return)
                 (format nil "~@[at ~a: ~]~a" (ignore-errors (crisp.compiler:error-source-location c)) c))))

(defun %api-stderr-diagnostics (text)
  "Lines of TEXT (what the compile wrote to *error-output*) that start with WARNING: as :warning diagnostics."
  (with-input-from-string (s text)
    (loop for line = (read-line s nil nil)
          while line
          for trimmed = (string-trim '(#\Space #\Return) line)
          when (alexandria:starts-with-subseq "WARNING:" trimmed)
            collect (%api-diagnostic :warning (string-trim " " (subseq trimmed (length "WARNING:")))))))

;;; ------------------------------------------------------------------------------------------------
;;; Temp directory
;;; ------------------------------------------------------------------------------------------------

(defun %api-make-temp-dir ()
  "A fresh, empty, private directory for one compile."
  (let* ((root (or *api-temp-root* (merge-pathnames "crisp-api/" (uiop:temporary-directory))))
         (dir (merge-pathnames (format nil "c~36r-~d/"
                                       (random (expt 36 8) (or *api-random-state*
                                                               (setf *api-random-state* (make-random-state t))))
                                       (incf *api-temp-counter*))
                               (uiop:ensure-directory-pathname root))))
    (ensure-directories-exist dir)
    (log:debug "compile API temp dir ~a" dir)
    dir))

(defun %api-write-sources (sources dir)
  "Writes each (TEXT . VIRTUAL-NAME) of SOURCES as DIR/<i>/<name> and returns
   (values FILES NAME-BY-PATH) -- the files in order, and an alist from namestring to virtual name.
   Each source gets its own subdirectory, so two sources may share a virtual name."
  (let ((files nil) (names nil))
    (loop for (text . vname) in sources
          for i from 0
          for name = (or vname (format nil "<source-~d>" i))
          ;; the file on disk: the virtual name's last component, made safe; the virtual name itself
          ;; is what diagnostics show.
          for safe = (substitute-if #\_ (lambda (ch) (find ch "<>:\"/\\|?*")) (file-namestring name))
          for path = (merge-pathnames (format nil "~d/~a" i (if (zerop (length safe)) "source.crisp" safe)) dir)
          do (ensure-directories-exist path)
             (with-open-file (out path :direction :output :if-exists :supersede :external-format :utf-8)
               (write-string text out))
             (push path files)
             (push (cons (namestring (truename path)) name) names))
    (values (nreverse files) names)))

(defun %api-virtual-name (pathname names)
  "The virtual name of the temp file PATHNAME (see %api-write-sources), or NIL."
  (when pathname
    (cdr (assoc (namestring (or (ignore-errors (truename pathname)) pathname)) names :test #'string-equal))))

;;; ------------------------------------------------------------------------------------------------
;;; Reading the .metacrisp back
;;; ------------------------------------------------------------------------------------------------

(defun %api-metadata-package ()
  "A private package to read .metacrisp text into, so its symbols never land in a compiler package.
   It imports CL:NIL and CL:T: a package that uses nothing would otherwise read `nil` (e.g.
   `:size-expr nil`) as a symbol of its own -- true, not false."
  (or (find-package :crisp.api-metadata)
      (let ((pkg (make-package :crisp.api-metadata :use nil)))
        (import (list nil t) pkg)
        pkg)))

(defun %api-read-metacrisp (path)
  "Every top-level form of the .metacrisp at PATH, read safely (*read-eval* off, private package)."
  (let ((*package* (%api-metadata-package))
        (*read-eval* nil))
    (with-open-file (s path :external-format :utf-8)
      (loop for form = (read s nil :eof) until (eq form :eof) collect form))))

(defun %api-section (forms key)
  "The body of the top-level (KEY ...) form in FORMS."
  (rest (find-if (lambda (f) (and (consp f) (eq (first f) key))) forms)))

(defun %api-kw (sym)
  "SYM (from the private package) as a keyword."
  (and sym (symbolp sym) (intern (symbol-name sym) :keyword)))

(defparameter +api-scalar-sizes+
  '((:char . 1) (:uchar . 1) (:short . 2) (:ushort . 2) (:half . 2) (:bfloat16 . 2)
    (:int . 4) (:uint . 4) (:float . 4) (:long . 8) (:ulong . 8) (:double . 8))
  "Bytes of each scalar type a physical slot can carry.")

(defun %api-size-align (type aliases structs)
  "(values BYTES ALIGNMENT) of TYPE laid out as C would: a scalar; (ARRAY T N); or a def-struct by
   name, plain or parameterised -- (POINT EARNESTNESS 3.0) carries a compile-time field that takes
   no space -- with each field at its natural alignment and the whole rounded to the largest.  NIL
   when TYPE cannot be sized.  STRUCTS: alist of struct name -> ((FIELD TYPE) ...)."
  (let* ((type (%api-resolve-type type aliases))
         (head (and (consp type) (symbolp (first type)) (symbol-name (first type))))
         (base (cond ((symbolp type) type) ((consp type) (first type))))
         (fields (and base (symbolp base) (cdr (assoc (symbol-name base) structs :test #'string-equal))))
         (scalar (and (symbolp type) (cdr (assoc (%api-kw type) +api-scalar-sizes+)))))
    (cond
      (scalar (values scalar scalar))
      ((and head (string-equal head "ARRAY") (integerp (third type)))
       (multiple-value-bind (s a) (%api-size-align (second type) aliases structs)
         (and s (values (* s (third type)) a))))
      (fields
       (let ((offset 0) (max-align 1))
         (dolist (f fields)
           (multiple-value-bind (s a) (%api-size-align (second f) aliases structs)
             (unless s (return-from %api-size-align nil))
             (setf offset (* a (ceiling offset a))
                   max-align (max max-align a))
             (incf offset s)))
         (values (* max-align (ceiling offset max-align)) max-align))))))

(defun %api-slot (entry &optional aliases structs)
  "One :physical-signature ENTRY, (INDEX TYPE), as a slot plist.  TYPE may be a def-type alias (a
   record's FFF field is a float), so it is resolved through ALIASES first.  A by-value struct is an
   :aggregate, sized by C layout rules (%api-size-align).  (Records and fixed arrays never reach here
   whole: the metacrisp splits them, one entry per field / element -- BUG 133.)"
  (let ((type (%api-resolve-type (second entry) aliases)))
    (cond
      ((and (consp type) (symbolp (first type)) (string= (symbol-name (first type)) "C-POINTER"))
       (list :type :pointer :size 8 :address-space (%api-kw (third type))))
      ;; a CUDA TMA descriptor, (TENSOR-MAP <option>): option A passes a pointer to the descriptor
      ;; in device global memory (see plan/ref.metacrisp)
      ((and (consp type) (symbolp (first type)) (string= (symbol-name (first type)) "TENSOR-MAP"))
       (list :type :pointer :size 8 :address-space :global))
      ((and (symbolp type) (assoc (%api-kw type) +api-scalar-sizes+))
       (list :type (%api-kw type) :size (cdr (assoc (%api-kw type) +api-scalar-sizes+)) :address-space nil))
      (t
       (let ((bytes (%api-size-align type aliases structs)))
         (if bytes
             (list :type :aggregate :size bytes :address-space nil)
             (list :type (and (symbolp type) (%api-kw type)) :size 0 :address-space nil)))))))

(defun %api-resolve-type (type aliases)
  "TYPE with def-type aliases followed (ALIASES: alist of symbol-name -> type form)."
  (loop repeat 32
        for found = (and (symbolp type) (assoc (symbol-name type) aliases :test #'string-equal))
        while found
        do (setf type (cdr found)))
  type)

(defun %api-roles (kind rank first last)
  "The (ROLE AXIS SLOT) entries of a parameter of KIND / RANK spanning physical slots FIRST..LAST.
   The layout is the one the hoisters fill (src/hoist-l0/main.lisp, cell ~L1210, tensor ~L1387)."
  (let ((expected-last (case kind (:scalar first) (:cell (+ first 2)) (:tensor (+ first 2 (* 3 rank))) (t last))))
    (unless (eql expected-last last)
      (log:error "compile API: a ~(~a~) of rank ~d spans slots ~d..~d, but its layout implies ~d..~d -- roles may be wrong"
                 kind rank first last first expected-last)))
  (ecase kind
    (:scalar (list (list :value 0 first)))
    (:cell (list (list :pointer 0 first) (list :byte-size 0 (+ first 1)) (list :offset 0 (+ first 2))))
    (:tensor
     (append (list (list :pointer 0 first) (list :byte-size 0 (+ first 1)))
             (loop for k below rank collect (list :offset k (+ first 2 k)))
             (loop for k below rank collect (list :stride k (+ first 2 rank k)))
             (loop for k below rank collect (list :extent k (+ first 2 (* 2 rank) k)))
             (list (list :length 0 (+ first 2 (* 3 rank))))))
    (:record (loop for slot from first to last for i from 0 collect (list :field i slot)))))

(defun %api-tensor-type-rank (type)
  "The rank a tensor TYPE form spells out -- (tensor ELEM N ...), (vector ...) = 1, (matrix ...) = 2 --
   or NIL when TYPE is not a tensor form.  Implicit (scratch) params carry no :rank key, only this."
  (let ((head (and (consp type) (symbolp (first type)) (symbol-name (first type)))))
    (cond ((null head) nil)
          ((string-equal head "TENSOR") (and (integerp (third type)) (third type)))
          ((string-equal head "VECTOR") 1)
          ((string-equal head "MATRIX") 2))))

(defun %api-type-align (type)
  "The :align a tensor TYPE form spells out: positional in (tensor ELEM N SPACE ALIGN ORDER), a
   keyword argument in (vector ELEM :align A ...) / (matrix ...).  NIL if absent."
  (let ((head (and (consp type) (symbolp (first type)) (symbol-name (first type)))))
    (cond ((null head) nil)
          ((string-equal head "TENSOR") (and (keywordp (fifth type)) (fifth type)))
          ((member head '("VECTOR" "MATRIX") :test #'string-equal)
           (let ((tail (cddr type))) (and (evenp (length tail)) (getf tail :align)))))))

(defun %api-param (decl aliases record-names &key implicit)
  "One :declared-signature DECL (or, with IMPLICIT, one :implicit-params entry) as a parameter plist.
   Item 2 (A9): implicit params share the list, told apart by :purpose."
  (let* ((type (%api-resolve-type (getf decl :type) aliases))
         (head (and (consp type) (symbolp (first type)) (symbol-name (first type))))
         (rank (or (getf decl :rank) (%api-tensor-type-rank type)))
         (range (getf decl :range))
         (purpose (cond ((eq (getf decl :kind) :tensor-map) :tensor-map)
                        ((getf decl :debug-logging) :debug-log)
                        (implicit :scratch)
                        (t :declared)))
         (kind (cond ((eq purpose :tensor-map) :scalar)   ; one slot: a descriptor pointer (CUDA TMA)
                     (rank :tensor)
                     ((and head (string-equal head "CELL")) :cell)
                     ;; a record or struct, plain or PARAMETERISED -- (v-point :earnestness 3.0)
                     ((let ((base (if (consp type) (first type) type)))
                        (and base (symbolp base) (member (symbol-name base) record-names :test #'string-equal)))
                      :record)
                     ;; BUG 133: a fixed array parameter is split like a record, one FIELD per element
                     ((and head (string-equal head "ARRAY")) :record)
                     (t :scalar)))
         (element (case kind
                    ((:tensor :cell) (and (consp type) (%api-kw (second type))))
                    (:scalar (and (symbolp type) (%api-kw type)))
                    (t nil)))
         (address-space (getf decl :address-space))
         (size-expr (getf decl :size-expr)))
    (list :name (getf decl :name)
          :purpose purpose
          :kind kind
          ;; direction means nothing for scratch
          :direction (if implicit nil (or (getf decl :direction) :in))
          :element-type element
          :rank (if (eq kind :tensor) rank 0)
          ;; The :align the kernel's author declared, reported so the caller passes matching data
          ;; (analyze-aref-expression): :compact is the fast path (extents only, no offset or stride
          ;; reads -- give it contiguous data), :compact-offset adds offsets, :strided (also the
          ;; fallback) honours both, so a PyTorch view passes through uncopied.
          :layout (when (eq kind :tensor)
                    (case (or (getf decl :align) (%api-type-align type))
                      (:compact :compact)
                      (:compact-offset :compact-offset)
                      (t :strided)))
          :address-space address-space
          ;; A11: GLOBAL scratch is zeroed before EVERY launch (stateful counters, BUG 084).
          ;; Workgroup-local scratch cannot be zeroed from the host.
          :zero-before-launch (and (eq purpose :scratch) (eq address-space :global))
          ;; The allocation rule, resolved against launch values by the launch object (step 2):
          ;; (:elements N ...) per axis, or (:rule KEYWORD) for a launch-relative size.
          :size (when (eq purpose :scratch)
                  (cond ((null size-expr) (list :elements 1))
                        ((integerp size-expr)
                         (cons :elements (make-list (max 1 (if (eq kind :tensor) rank 1)) :initial-element size-expr)))
                        ((and (consp size-expr) (every #'integerp size-expr)) (cons :elements size-expr))
                        ((keywordp size-expr) (list :rule size-expr))
                        (t (list :rule size-expr))))
          :roles (%api-roles kind (or rank 0) (first range) (second range)))))

(defun %api-kernels-of-metacrisp (path)
  "The kernel plists described by the .metacrisp at PATH."
  (let* ((forms (%api-read-metacrisp path))
         (aliases (loop for d in (%api-section forms :aliases)
                        when (and (consp d) (string-equal (symbol-name (first d)) "DEF-TYPE"))
                          collect (cons (symbol-name (second d)) (third d))))
         (record-names (loop for d in (append (%api-section forms :records) (%api-section forms :structs))
                             when (consp d) collect (symbol-name (second d))))
         ;; struct name -> its fields ((NAME TYPE) ...), for sizing by-value struct slots
         (structs (loop for d in (%api-section forms :structs)
                        when (and (consp d) (symbolp (second d)))
                          collect (cons (symbol-name (second d))
                                        (remove-if-not (lambda (f) (and (consp f) (= (length f) 2))) (cddr d))))))
    (loop with profile = (first (%api-section forms :hardware-profile))
          for k in (%api-section forms :kernels)
          ;; declared + implicit, in SLOT order (A9: one list)
          for params = (sort (append (mapcar (lambda (d) (%api-param d aliases record-names))
                                             (getf k :declared-signature))
                                     (mapcar (lambda (d) (%api-param d aliases record-names :implicit t))
                                             (getf k :implicit-params)))
                             #'< :key (lambda (p) (or (third (first (getf p :roles))) most-positive-fixnum)))
          collect (list :name (getf k :name)
                        :slots (%api-mark-pointer-slots
                                (mapcar (lambda (e) (%api-slot e aliases structs)) (getf k :physical-signature)) params)
                        :params params
                        :geometry (%api-geometry k params)
                        ;; lanes per warp for :match-num-warps-per-workgroup scratch; NIL = no
                        ;; profile, and the launch object falls back to 32 (as the hoister does)
                        :warp-size (and (consp profile) (evenp (length profile))
                                        (let ((w (getf profile :simd-width))) (and (integerp w) w)))))))

;;; ------------------------------------------------------------------------------------------------
;;; Launch geometry (item 2, step 2): the kernel's declarations, normalised for the C launch object
;;; ------------------------------------------------------------------------------------------------

(defun %api-decl-plist (form)
  "The keyword arguments of a declaration FORM such as (global-size :set-to 256), or NIL."
  (and (consp form) (evenp (length (rest form))) (rest form)))

(defun %api-param-ref (sym params)
  "SYM (a name in a declaration) as (:param INDEX) into PARAMS, or (:unknown NAME)."
  (let ((i (position (symbol-name sym) params :key (lambda (p) (getf p :name)) :test #'string-equal)))
    (if i (list :param i) (list :unknown (string-downcase (symbol-name sym))))))

(defun %api-geometry (k params)
  "Kernel K's launch geometry declarations, normalised -- the same reading the L0 hoister gives them
   (src/hoist-l0/main.lisp %l0-emit-dispatch):
     :local     (X Y)  from local-size :set-to (int or list); (1 1) otherwise.  local-size :derive-from
                       is NOT honoured, as in the hoister.
     :dispatch  :global-size, else :num-groups (which the hoister reads exactly like global-size), else NIL
     :strategy  :one-thread-per | :exact | :strided | :interleaved | NIL
     :set-to    list of integers and (:param I) references
     :derive    (:tensor I) for a bare symbol, (:scalars I ...) for a list
     :tile-shape list of integers;  :occupancy a number"
  (let* ((local (%api-decl-plist (getf k :local-size)))
         (ls (getf local :set-to))
         (global (getf k :global-size))
         (groups (getf k :num-groups))
         (dispatch-form (or global groups))
         (d (%api-decl-plist dispatch-form))
         (set-to (getf d :set-to))
         (derive (getf d :derive-from))
         (ref (lambda (x) (if (integerp x) x (%api-param-ref x params)))))
    (list :local (cond ((integerp ls) (list ls 1))
                       ((and (consp ls) (integerp (first ls)))
                        (list (first ls) (if (integerp (second ls)) (second ls) 1)))
                       (t (list 1 1)))
          :dispatch (cond (global :global-size) (groups :num-groups))
          :strategy (let ((s (getf d :strategy))) (and (keywordp s) s))
          :set-to (cond ((null set-to) nil)
                        ((atom set-to) (list (funcall ref set-to)))
                        (t (mapcar ref set-to)))
          :derive (cond ((null derive) nil)
                        ((symbolp derive) (cons :tensor (rest (%api-param-ref derive params))))
                        ((consp derive) (cons :scalars (mapcar (lambda (s) (second (%api-param-ref s params))) derive))))
          :tile-shape (let ((ts (getf d :tile-shape))) (and (consp ts) (every #'integerp ts) ts))
          :occupancy (let ((o (getf d :occupancy))) (and (realp o) o))
          ;; CUDA thread-block clusters (endeavour 152): the shape is baked into the PTX, so the
          ;; launch only has to make the grid divisible by it -- pad under :strided, refuse under
          ;; :exact or when the kernel uses its cluster's reach (multicast / cluster barrier, BUG 049).
          :cluster (let ((c (getf k :effective-cluster-size)))
                     (and (consp c) (every #'integerp c) (> (reduce #'* c) 1) c))
          :cluster-reach (and (getf k :cluster-reach) t))))

(defun %api-mark-pointer-slots (slots params)
  "SLOTS with every parameter's :pointer-role slot reported as a pointer in that parameter's address
   space, and every other cell / tensor layout slot (byte size, offsets, strides, extents, length) as
   the ulong it always is.  The .metacrisp records the TARGET's view of a slot, which is not always
   the layout: SPIR-V says (C-POINTER ADDRESS-SPACE GLOBAL) but PTX says ULONG for a pointer (a
   .param .b64), and a PTX scratch cell is listed (ULONG VOIDP ULONG) although its slots are pointer,
   byte size, offset (found on the H100, 2026-10-22).  The roles are the same on every target, so
   they decide."
  (let ((slots (mapcar #'copy-list slots)))
    (dolist (p params slots)
      (dolist (r (getf p :roles))
        (when (< -1 (third r) (length slots))
          (let ((s (nth (third r) slots)))
            (case (first r)
              (:pointer
               (setf (getf s :type) :pointer
                     (getf s :size) 8
                     (getf s :address-space) (getf p :address-space)))
              ((:byte-size :offset :stride :extent :length)
               (setf (getf s :type) :ulong
                     (getf s :size) 8
                     (getf s :address-space) nil)))
            (setf (nth (third r) slots) s)))))))

;;; ------------------------------------------------------------------------------------------------
;;; --differentiate: describe the primal too (S2), and pair each adjoint with its parameter
;;; ------------------------------------------------------------------------------------------------

(defun %api-write-kernel-metacrisp (kernel path source output-targets)
  "Writes a .metacrisp for the one KERNEL (a symbol) at PATH -- the same sequence
   generate-metadata-for-file writes per kernel, minus its --differentiate redirection to K_GRAD."
  (multiple-value-bind (aliases structs) (crisp.compiler::collect-kernel-dependencies (list kernel))
    (with-open-file (stream path :direction :output :if-exists :supersede)
      (format stream ";; generated by crisp-compile (compile API: primal of a --differentiate compile)~%~%")
      (crisp.compiler::serialize-aliases stream aliases)
      (crisp.compiler::serialize-structs stream structs)
      (crisp.compiler::%hp-serialize-active-profile stream)
      (crisp.compiler::serialize-kernels stream (list kernel) :source source :output-targets output-targets)))
  path)

(defun %api-differentiate-kernels (filepath output captured-forms grad-meta-paths)
  "The kernels of a --differentiate compile, in order: each forward kernel, then its _grad.
   crisp-compile's .metacrisp describes ONLY the _grad kernel (F4), though the module holds both,
   so the primal's is written here, into the compile's private temp directory -- the CLI's files
   are untouched (tests/run-specs.lisp tells a backward metacrisp by its text, so a primal added
   to that file would trip %152-assert-no-schedule-leak).
   GRAD-META-PATHS are generate-metadata-for-file's, one per forward kernel in the same order as
   the names below (it derives them the same way)."
  (let ((forward (if captured-forms
                     (crisp.compiler::extract-defined-kernels captured-forms)
                     (crisp.compiler::%only-forward-kernels (reverse crisp.compiler::*compiled-kernels*)))))
    (log:debug "compile API --differentiate: forward kernels ~s, grad metacrisps ~s" forward grad-meta-paths)
    (if (/= (length forward) (length grad-meta-paths))
        ;; e.g. no kernels at all: generate-metadata-for-file wrote one empty file
        (loop for p in grad-meta-paths when (probe-file p) append (%api-kernels-of-metacrisp p))
        (loop for k in forward
              for grad-path in grad-meta-paths
              for primal-path = (make-pathname :name (format nil "~a__primal_~(~a~)" (pathname-name filepath) (symbol-name k))
                                               :type "metacrisp" :defaults filepath)
              append (%api-kernels-of-metacrisp
                      (%api-write-kernel-metacrisp k primal-path (namestring filepath) (list output)))
              when (probe-file grad-path) append (%api-kernels-of-metacrisp grad-path)))))

(defun %api-pair-adjoints (kernels)
  "KERNELS with :grad-of on every kernel and :adjoint-of on every parameter (NIL when not a gradient).
   A kernel <K>_grad is the gradient of kernel K when both are present.  In it, parameter P is the
   adjoint of Q when P is <Q>_grad, Q is a parameter of K, and P is NOT -- so a user's own parameter
   named x_grad is never mistaken for an adjoint.  The AD pass names adjoints this way; deriving the
   pairing here keeps the compiler untouched (decision for review: it could instead be emitted by
   the AD pass into the metacrisp)."
  (flet ((kname (k) (getf k :name))
         (pnames (k) (mapcar (lambda (p) (getf p :name)) (getf k :params))))
    (loop for k in kernels
          for name = (kname k)
          for primal = (and (> (length name) 5)
                            (string= "_grad" name :start2 (- (length name) 5))
                            (find (subseq name 0 (- (length name) 5)) kernels :key #'kname :test #'string=))
          collect (append (list :name name
                                :grad-of (and primal (kname primal))
                                :geometry (getf k :geometry)
                                :warp-size (getf k :warp-size)
                                :slots (getf k :slots)
                                :params (loop with primal-names = (and primal (pnames primal))
                                              for p in (getf k :params)
                                              for pn = (getf p :name)
                                              for q = (and primal
                                                           (> (length pn) 5)
                                                           (string= "_grad" pn :start2 (- (length pn) 5))
                                                           (subseq pn 0 (- (length pn) 5)))
                                              collect (append p (list :adjoint-of
                                                                      (and q
                                                                           (member q primal-names :test #'string=)
                                                                           (not (member pn primal-names :test #'string=))
                                                                           q)))))))))

(defun %api-read-octets (path)
  "The bytes of the file at PATH."
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s)
      v)))

;;; ------------------------------------------------------------------------------------------------
;;; The compile
;;; ------------------------------------------------------------------------------------------------

(defun %api-compile-in-dir (files names settings backend)
  "Compiles FILES (the temp copies of the sources) for BACKEND with SETTINGS.  Returns the result
   plist.  Mirrors compile-files for ONE target, with metadata always on and every failure caught."
  (let* ((primary (car (last files)))
         (filepath (truename primary))
         (primary-name (%api-virtual-name primary names))
         (debug-p (getf settings :debug))
         (crisp.compiler:*target-backend* backend)
         (crisp.compiler::*emit-metadata* t)
         (captured-forms nil)
         (output nil))
    (crisp.compiler:initialize-compiler :log-level :off
                                        :runtime-checks (getf settings :runtime-checks)
                                        :differentiate (getf settings :differentiate)
                                        :math-precision (getf settings :math-precision)
                                        :force-math-precision (getf settings :force-math-precision)
                                        :denormal-handling (getf settings :denormal-handling)
                                        :hardware-profile (getf settings :hardware-profile))
    (setf crisp.compiler::*ir-target-arch*
          (let ((a (getf settings :ir-target-arch))) (and a (intern (string-upcase a) :keyword))))
    (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
           (builder (crisp.llvm-bindings:llvm-create-builder))
           (di-builder (when debug-p (crisp.llvm-bindings:llvm-create-di-builder module)))
           (di-compile-unit (when debug-p (initialize-debug-context module di-builder filepath))))
      (unwind-protect
           (handler-case
               (progn
                 (if (getf settings :single-pass)
                     (%compile-files-single-pass files module builder di-builder di-compile-unit)
                     (let* ((*package* (find-package :crisp-language))
                            (forms (%read-crisp-forms files))
                            (location-map (when debug-p (crisp.compiler:generate-location-map forms))))
                       (setf captured-forms forms)
                       (crisp.compiler:compile-module forms module builder di-builder di-compile-unit location-map)))
                 (setf output (%emit-target-output backend module filepath debug-p)))
             ;; A reader error knows its stream, so its file; anything else is charged to the primary.
             (stream-error (c)
               (log:info "compile API: stream error ~a" c)
               (return-from %api-compile-in-dir
                 (list :status :compile-error
                       :diagnostics (list (%api-diagnostic
                                           :error (if (typep c 'end-of-file)
                                                      (format nil "unexpected end of file (unbalanced parentheses?)")
                                                      (%api-condition-message c))
                                           :file (or (%api-virtual-name
                                                      (ignore-errors (pathname (stream-error-stream c))) names)
                                                     primary-name)))
                       :modules nil)))
             (error (c)
               (log:info "compile API: compile error ~a" c)
               (return-from %api-compile-in-dir
                 (list :status :compile-error
                       :diagnostics (list (%api-diagnostic :error (%api-condition-message c) :file primary-name))
                       :modules nil))))
        (when debug-p
          (crisp.llvm-bindings:llvm-di-builder-finalize di-builder)
          (crisp.llvm-bindings:llvm-dispose-di-builder di-builder))
        (crisp.llvm-bindings:llvm-dispose-builder builder)
        (crisp.llvm-bindings:llvm-dispose-module module)))
    ;; The backend ran; did it produce anything?
    (let ((out-path (second output)))
      (unless (and out-path (probe-file out-path))
        (return-from %api-compile-in-dir
          (list :status :internal-error
                :diagnostics (list (%api-diagnostic :error (format nil "the ~(~a~) backend produced no output" backend)
                                                    :file primary-name))
                :modules nil)))
      (let* ((meta-paths (%generate-file-metadata filepath (list output) captured-forms))
             (kernels (if (getf settings :differentiate)
                          (%api-differentiate-kernels filepath output captured-forms meta-paths)
                          (loop for p in meta-paths
                                when (probe-file p) append (%api-kernels-of-metacrisp p)))))
        (setf kernels (%api-pair-adjoints kernels))
        (log:debug "compile API: ~d byte module, kernels ~s" (with-open-file (s out-path) (file-length s))
                   (mapcar (lambda (k) (getf k :name)) kernels))
        (list :status :ok
              :diagnostics nil
              :modules (list (list :binary (%api-read-octets out-path) :kernels kernels)))))))

(defun compile-sources (sources &key (target "spv") flags)
  "The compile API's Lisp core (endeavour 190).  Compiles SOURCES -- a list of (TEXT . VIRTUAL-NAME),
   compiled in order as if one file -- for TARGET (\"spv\" or \"ptx\") with FLAGS (strings, as
   crisp-compile takes them).  Never quits, never writes to *standard-output*, leaves no files.
   Returns a plist:
     (:status :ok | :compile-error | :invalid-argument | :internal-error
      :diagnostics ((:severity :error|:warning|:note :message STR :file STR :line N :column N) ...)
      :modules ((:binary OCTETS
                 :kernels ((:name STR
                            :slots ((:type KW :size N :address-space KW-or-NIL) ...)      ; physical args
                            :params ((:name STR :kind :scalar|:cell|:tensor|:record :direction :in|:out
                                      :element-type KW :rank N :address-space KW-or-NIL
                                      :roles ((ROLE AXIS SLOT) ...)) ...)) ...)))))
   v1 always yields exactly one module on success."
  (log:info "compile API: ~d source(s), target ~a, flags ~s" (length sources) target flags)
  (let ((backend (%api-parse-target target)))
    (unless backend
      (return-from compile-sources
        (list :status :invalid-argument
              :diagnostics (list (%api-diagnostic :error (format nil "unknown target ~s (expected spv or ptx)" target)))
              :modules nil)))
    (when (null sources)
      (return-from compile-sources
        (list :status :invalid-argument
              :diagnostics (list (%api-diagnostic :error "no sources to compile"))
              :modules nil)))
    (multiple-value-bind (settings flag-error) (%api-parse-flags flags)
      (when flag-error
        (return-from compile-sources
          (list :status :invalid-argument :diagnostics (list (%api-diagnostic :error flag-error)) :modules nil)))
      (let ((dir (%api-make-temp-dir))
            (stdout (make-string-output-stream))
            (stderr (make-string-output-stream))
            (result nil))
        (unwind-protect
             (handler-case
                 (let ((*standard-output* stdout)
                       (*error-output* stderr))
                   ;; Every compile after the first in an image re-runs the template macro
                   ;; definitions (initialize-compiler does not clear CL macros), so SBCL warns
                   ;; "redefining ... in DEFMACRO" -- noise a one-shot CLI never sees, but a
                   ;; long-lived server would hand to every caller as a diagnostic.
                   (handler-bind ((sb-kernel:redefinition-warning #'muffle-warning))
                     (multiple-value-bind (files names) (%api-write-sources sources dir)
                       (setf result (%api-compile-in-dir files names settings backend)))))
               (serious-condition (c)
                 (log:error "compile API: internal failure ~a" c)
                 (setf result (list :status :internal-error
                                    :diagnostics (list (%api-diagnostic :error (%api-condition-message c)))
                                    :modules nil))))
          (ignore-errors (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))
        (let ((out-text (get-output-stream-string stdout))
              (err-text (get-output-stream-string stderr)))
          (when (plusp (length out-text)) (log:debug "compile API: compiler stdout ~a" out-text))
          (when (plusp (length err-text)) (log:debug "compile API: compiler stderr ~a" err-text))
          (setf (getf result :diagnostics)
                (append (getf result :diagnostics)
                        (%api-flag-warnings settings)
                        (%api-stderr-diagnostics err-text))))
        (log:info "compile API: status ~a, ~d diagnostic(s)" (getf result :status) (length (getf result :diagnostics)))
        result))))

;;; ================================================================================================
;;; The compile server (A1: out of process).  `crisp-compile --serve` reads requests on stdin and
;;; writes results on stdout, one at a time, until stdin closes.  c-api/src/crisp.c is the client.
;;;
;;; FRAMING (both directions): a record is   <tag> SP <length> LF <length bytes> LF
;;; tag is [a-z.-]+, length is decimal, the payload is raw bytes (UTF-8 text, or the binary module).
;;; Binary-safe, and trivial to parse from C or Python.
;;;
;;; On start the server writes   hello <n> LF "crisp-compile-server <protocol-version>" LF
;;;
;;; REQUEST:   target "spv"|"ptx"
;;;            flag "<one flag>"                       (zero or more, in order)
;;;            source-name "<virtual name>"           (optional, names the NEXT source)
;;;            source "<text>"                         (one or more, in order)
;;;            end ""
;;; RESPONSE:  status "ok"|"compile-error"|"invalid-argument"|"internal-error"
;;;            then, in order, any of these groups (a group's fields follow its opening record):
;;;              diag ""    diag.severity diag.message [diag.file] diag.line diag.column
;;;              module ""  module.binary
;;;              kernel ""  kernel.name [kernel.grad-of]
;;;                         kernel.local "X Y" [kernel.dispatch] [kernel.strategy] [kernel.set-to "N|pI ..."]
;;;                         [kernel.derive "tensor pI" | "scalars pI ..."] [kernel.tile-shape "N ..."]
;;;                         [kernel.occupancy "R"] [kernel.warp-size "N"]       (launch geometry)
;;;                         [kernel.cluster "X Y Z"] [kernel.cluster-reach "1"] (CUDA clusters)
;;;              slot ""    slot.type slot.size [slot.address-space]        (belongs to the last kernel)
;;;              param ""   param.name param.kind [param.direction] [param.element-type] param.rank
;;;                         [param.layout] [param.address-space] [param.adjoint-of]
;;;                         param.purpose [param.zero-before-launch "1"]
;;;                         [param.size "elements N ..." | "rule <keyword>"]     (scratch only)
;;;              role "<role> <axis> <slot>"                                (belongs to the last param)
;;;            end ""
;;; A field in [brackets] is omitted when it has no value.  Kernels belong to the last module.
;;; ================================================================================================

(defparameter +api-protocol-version+ 1
  "Bumped on any incompatible change to the server framing or record set.")

(defun %proto-octets (payload)
  "PAYLOAD (a string, an integer, a keyword or an octet vector) as an octet vector."
  (etypecase payload
    ((vector (unsigned-byte 8)) payload)
    (string (sb-ext:string-to-octets payload :external-format :utf-8))
    (integer (%proto-octets (princ-to-string payload)))
    (symbol (%proto-octets (string-downcase (symbol-name payload))))))

(defun %proto-write-record (stream tag payload)
  "Writes one record (see the framing above) to the octet STREAM.  A NIL payload writes nothing."
  (when payload
    (let ((bytes (%proto-octets payload)))
      (write-sequence (%proto-octets (format nil "~a ~d" tag (length bytes))) stream)
      (write-byte 10 stream)
      (write-sequence bytes stream)
      (write-byte 10 stream))))

(defun %proto-read-record (stream)
  "Reads one record from the octet STREAM: (values TAG PAYLOAD-OCTETS), or NIL at end of file.
   Signals an error on a malformed record."
  (let ((header (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop for b = (read-byte stream nil nil)
          do (cond ((null b) (if (zerop (length header))
                                 (return-from %proto-read-record nil)
                                 (error "compile server: end of file inside a record header")))
                   ((= b 10) (return))
                   (t (vector-push-extend b header))))
    (let* ((text (sb-ext:octets-to-string (coerce header '(vector (unsigned-byte 8))) :external-format :utf-8))
           (space (position #\Space text))
           (tag (and space (subseq text 0 space)))
           (len (and space (parse-integer text :start (1+ space) :junk-allowed t))))
      (unless (and tag len (>= len 0))
        (error "compile server: malformed record header ~s" text))
      (let ((payload (make-array len :element-type '(unsigned-byte 8))))
        (unless (= (read-sequence payload stream) len)
          (error "compile server: end of file inside a ~a record" tag))
        (unless (eql (read-byte stream nil nil) 10)
          (error "compile server: a ~a record does not end in a newline" tag))
        (values tag payload)))))

(defun %proto-read-request (stream)
  "Reads one request from STREAM.  Returns (values TARGET FLAGS SOURCES), or NIL at end of file.
   SOURCES is a list of (TEXT . VIRTUAL-NAME), as compile-sources takes it."
  (let ((target nil) (flags nil) (sources nil) (pending-name nil) (any nil))
    (loop
      (multiple-value-bind (tag payload) (%proto-read-record stream)
        (cond
          ((null tag)
           (when any (error "compile server: end of file inside a request"))
           (return-from %proto-read-request nil))
          (t
           (setf any t)
           (let ((text (sb-ext:octets-to-string payload :external-format :utf-8)))
             (cond ((string= tag "target") (setf target text))
                   ((string= tag "flag") (push text flags))
                   ((string= tag "source-name") (setf pending-name (if (zerop (length text)) nil text)))
                   ((string= tag "source") (push (cons text pending-name) sources) (setf pending-name nil))
                   ((string= tag "end") (return-from %proto-read-request
                                          (values target (nreverse flags) (nreverse sources))))
                   (t (error "compile server: unknown request record ~s" tag))))))))))

(defun %proto-write-result (stream result)
  "Writes RESULT (a compile-sources plist) to STREAM as a RESPONSE (see the framing above)."
  (flet ((rec (tag payload) (%proto-write-record stream tag payload)))
    (rec "status" (getf result :status))
    (dolist (d (getf result :diagnostics))
      (rec "diag" "")
      (rec "diag.severity" (getf d :severity))
      (rec "diag.message" (or (getf d :message) ""))
      (rec "diag.file" (getf d :file))
      (rec "diag.line" (or (getf d :line) 0))
      (rec "diag.column" (or (getf d :column) 0)))
    (dolist (m (getf result :modules))
      (rec "module" "")
      (rec "module.binary" (getf m :binary))
      (dolist (k (getf m :kernels))
        (rec "kernel" "")
        (rec "kernel.name" (getf k :name))
        (rec "kernel.grad-of" (getf k :grad-of))
        ;; launch geometry (item 2): see %api-geometry.  A parameter reference travels as p<index>,
        ;; an unresolvable name as ?<name>.
        (let ((g (getf k :geometry)))
          (flet ((tok (x) (cond ((integerp x) (princ-to-string x))
                                ((and (consp x) (eq (first x) :param)) (format nil "p~d" (second x)))
                                ((consp x) (format nil "?~a" (second x)))
                                (t (format nil "?~a" x)))))
            (rec "kernel.local" (format nil "~{~d~^ ~}" (getf g :local)))
            (rec "kernel.dispatch" (getf g :dispatch))
            (rec "kernel.strategy" (getf g :strategy))
            (rec "kernel.set-to" (and (getf g :set-to) (format nil "~{~a~^ ~}" (mapcar #'tok (getf g :set-to)))))
            (rec "kernel.derive" (let ((dv (getf g :derive)))
                                   (and dv (format nil "~(~a~)~{ ~a~}" (first dv)
                                                   (mapcar (lambda (i) (if (integerp i) (format nil "p~d" i) (format nil "?~a" i)))
                                                           (rest dv))))))
            (rec "kernel.tile-shape" (and (getf g :tile-shape) (format nil "~{~d~^ ~}" (getf g :tile-shape))))
            (rec "kernel.occupancy" (and (getf g :occupancy) (format nil "~f" (getf g :occupancy))))
            (rec "kernel.cluster" (and (getf g :cluster) (format nil "~{~d~^ ~}" (getf g :cluster))))
            (rec "kernel.cluster-reach" (and (getf g :cluster-reach) "1"))))
        (rec "kernel.warp-size" (getf k :warp-size))
        (dolist (s (getf k :slots))
          (rec "slot" "")
          (rec "slot.type" (getf s :type))
          (rec "slot.size" (getf s :size))
          (rec "slot.address-space" (getf s :address-space)))
        (dolist (p (getf k :params))
          (rec "param" "")
          (rec "param.name" (getf p :name))
          (rec "param.kind" (getf p :kind))
          (rec "param.direction" (getf p :direction))
          (rec "param.element-type" (getf p :element-type))
          (rec "param.rank" (or (getf p :rank) 0))
          (rec "param.layout" (getf p :layout))
          (rec "param.address-space" (getf p :address-space))
          (rec "param.adjoint-of" (getf p :adjoint-of))
          (rec "param.purpose" (getf p :purpose))
          (rec "param.zero-before-launch" (when (getf p :zero-before-launch) "1"))
          ;; "elements N ..." or "rule <keyword>" -- resolved by the C launch object (item 2, step 2)
          (rec "param.size" (let ((sz (getf p :size)))
                              (when sz
                                (format nil "~(~a~)~{ ~(~a~)~}" (first sz) (rest sz)))))
          (dolist (r (getf p :roles))
            (rec "role" (format nil "~(~a~) ~d ~d" (first r) (second r) (third r)))))))
    (rec "end" "")
    (finish-output stream)))

(defun serve-requests (in out)
  "The compile server loop: reads requests from the octet stream IN until end of file, answers each
   on the octet stream OUT.  A malformed request is answered with internal-error and ends the loop
   (the stream can no longer be trusted to be in sync); the client then starts a fresh server."
  (loop
    (multiple-value-bind (target flags sources)
        (handler-case (%proto-read-request in)
          (error (e)
            (log:error "compile server: bad request: ~a" e)
            (%proto-write-result out (list :status :internal-error
                                           :diagnostics (list (%api-diagnostic :error (format nil "compile server: ~a" e)))))
            (return)))
      (when (and (null target) (null sources))
        (log:info "compile server: end of input, exiting")
        (return))
      (log:info "compile server: request target ~a, ~d flag(s), ~d source(s)" target (length flags) (length sources))
      (%proto-write-result out (compile-sources sources :target target :flags flags)))))

(defun serve-main ()
  "`crisp-compile --serve`: speaks the compile-server protocol on the process's stdin / stdout.
   The protocol owns stdout, so every Lisp stream that might print is pointed at stderr first."
  (let* ((in (sb-sys:make-fd-stream (sb-sys:fd-stream-fd sb-sys:*stdin*)
                                    :input t :element-type '(unsigned-byte 8) :buffering :full))
         (out (sb-sys:make-fd-stream (sb-sys:fd-stream-fd sb-sys:*stdout*)
                                     :output t :element-type '(unsigned-byte 8) :buffering :full))
         (*standard-output* *error-output*)
         (*trace-output* *error-output*))
    ;; log4cl's console appender writes to the REAL stdout whatever *standard-output* is bound to,
    ;; and the protocol owns stdout, so logging is OFF in the server.  (compile-sources'
    ;; initialize-compiler also sets :off; this covers the records logged before it runs.)
    ;; TODO(190): an opt-in log to stderr or a file for debugging the server.
    (log:config :off)
    (%proto-write-record out "hello" (format nil "crisp-compile-server ~d" +api-protocol-version+))
    (finish-output out)
    (serve-requests in out)
    (finish-output out)))
