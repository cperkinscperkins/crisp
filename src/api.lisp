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
               (setf (getf settings key) kw))))
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
  "The warnings crisp-compile prints for SETTINGS (parse-cli-args), as diagnostics."
  (let ((out nil))
    (when (getf settings :force-math-precision)
      (push (%api-diagnostic :warning "--force-math-precision overrides all in-source precision choices; use for testing/validation only.") out))
    (when (and (eq (or (getf settings :force-math-precision) (getf settings :math-precision)) :fast)
               (eq (getf settings :denormal-handling) :preserve))
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
  "A private package to read .metacrisp text into, so its symbols never land in a compiler package."
  (or (find-package :crisp.api-metadata) (make-package :crisp.api-metadata :use nil)))

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

(defun %api-slot (entry)
  "One :physical-signature ENTRY, (INDEX TYPE), as a slot plist."
  (let ((type (second entry)))
    (if (and (consp type) (string= (symbol-name (first type)) "C-POINTER"))
        (list :type :pointer :size 8 :address-space (%api-kw (third type)))
        (let ((kw (%api-kw type)))
          (list :type kw :size (or (cdr (assoc kw +api-scalar-sizes+)) 0) :address-space nil)))))

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

(defun %api-param (decl aliases record-names)
  "One :declared-signature DECL as a parameter plist."
  (let* ((type (%api-resolve-type (getf decl :type) aliases))
         (head (and (consp type) (symbolp (first type)) (symbol-name (first type))))
         (rank (getf decl :rank))
         (range (getf decl :range))
         (kind (cond (rank :tensor)
                     ((and head (string-equal head "CELL")) :cell)
                     ((and (symbolp type) (member (symbol-name type) record-names :test #'string-equal)) :record)
                     (t :scalar)))
         (element (case kind
                    ((:tensor :cell) (and (consp type) (%api-kw (second type))))
                    (:scalar (%api-kw type))
                    (t nil))))
    (list :name (getf decl :name)
          :kind kind
          :direction (or (getf decl :direction) :in)
          :element-type element
          :rank (if (eq kind :tensor) rank 0)
          :address-space (getf decl :address-space)
          :roles (%api-roles kind (or rank 0) (first range) (second range)))))

(defun %api-kernels-of-metacrisp (path)
  "The kernel plists described by the .metacrisp at PATH."
  (let* ((forms (%api-read-metacrisp path))
         (aliases (loop for d in (%api-section forms :aliases)
                        when (and (consp d) (string-equal (symbol-name (first d)) "DEF-TYPE"))
                          collect (cons (symbol-name (second d)) (third d))))
         (record-names (loop for d in (append (%api-section forms :records) (%api-section forms :structs))
                             when (consp d) collect (symbol-name (second d)))))
    (loop for k in (%api-section forms :kernels)
          collect (list :name (getf k :name)
                        :slots (mapcar #'%api-slot (getf k :physical-signature))
                        :params (mapcar (lambda (d) (%api-param d aliases record-names))
                                        (getf k :declared-signature))))))

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
             (kernels (loop for p in meta-paths
                            when (probe-file p) append (%api-kernels-of-metacrisp p))))
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
                   (multiple-value-bind (files names) (%api-write-sources sources dir)
                     (setf result (%api-compile-in-dir files names settings backend))))
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
