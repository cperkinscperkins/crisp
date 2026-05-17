Hello Claude,

Welcome to Crisp. This is a Lisp dialect for writing GPU kernels that I've been developing.

We are working on the compiler implementation.

Important Files
----------------

### The Design Document
The (very important) design document is: @crisp/docs/ideal_001.md   However, that document is a rather long.
There is a web version that is broken out by "chapter" here: https://cperkinscperkins.github.io/crisp/docs/index.html
Or those same chapters are on disk under @crisp/docs/chapters/


#### Things about Crisp
@crisp/docs/crisp-curios.md  has a very short list of things about Crisp that are NOT like other languages and other compilers. 




### The Source Code
The main source code is in: @crisp/src/

@crisp/docs/reference.md is an auto-generated file that documents ALL the 
functions and top level forms (except packages). You can quickly absorb the shape
of the current implementation by reading that file.
@crisp/src/package.lisp gives a similar overview.


But perhaps even better, look at @crisp/docs/call_graph.md  It has a complete call graph of everything, with arguments and packages and files.  It's only 650 lines. Read it!!


### The Testing
@crisp/docs/tests.md describes the testing, the "spine", our custom directives and how to run. 

### The Plan
The @crisp/plan/scramble.md file is the working plan. And @crisp/plan/bugs.md documents known issues.

The Toolset
-----------
The implementation is with SBCL and LLVM Dev. 


How to Build the compiler and Run Tests
---------------------------------------

#### Build The Compiler and the Hoist Application
`$ sbcl --non-interactive --load .\build\build.lisp`

Don't forget to build the compiler BEFORE running tests.




#### Running Tests
```
# run the unit tests
$ sbcl --non-interactive --load .\tests\run-ci.lisp     

# run the E2E tests
$ sbcl --script .\tests\run-specs.lisp  

# run the negative tests (errors)
$ sbcl --script .\tests\run-error-specs.lisp
```

QUICK NOTE: Do NOT rely on the validators to verify a new feature. Check the LLVM-IR, or the .spt, or the metadata, or whatever, yourself MANUALLY.  

### GitHub Actions CI
We use GitHub Actions for CI.  The `.github/workflows/ci.yml` governs that. It builds, runs unit tests, and runs e2e tests.  Generally some E2E and "Negative" test work is duplicated in both
`ci.yml` and `run-all-tests.bat`.


### Generate C Code

The Crisp compiler can generate C "hoisting" code. Presently, LevelZero is the only backend, but
others will follow.

```
# this will compile the kernel to .spv and also output a .c file which can "hoist" it .
.\bin\crisp-compile.exe --ir-target=spv --hoist=l0 ./tests/spec/029-hoist-l0/01-minimal-kernl.crisp

# use any C compiler.  If docker is available, this Crisp installation can use that 
# with it's own crisp-c-validator image.

docker run --rm `
  -v "${PWD}:/workspace" `
  -v "C:\Users\cperk\Documents\level-zero\include:/usr/local/include" `
  crisp-c-validator gcc -c -I/usr/local/include `
  /workspace/tests/spec/029-hoist-l0/01-minimal-kernel_noop_noop_hoist_L0.cpp
```


### Other
The @crisp/INSTALL.md file documents how to clone, get toolsets, build the compiler and run tests, 
it is written for end users.   

TDD and the spine of specs
--------------------------
```
sbcl --script tests/run-specs.lisp
```

The E2E tests have been reorganized and are now under the `tests/specs/` directory. Under that directory
are a series of subdirectories ( 001-def-function, 002-type-conversion, etc) that in turn contain a series of
tests (01-return_7.crisp 02-def-function_primitive.crisp etc)

This now serves both as our E2E test suite, but also a record of where we've been and where we are going.

The `tests/ci-stop.txt` file contains the name of the directory where the E2E tests should complete and then stop.
The presumption is that AFTER that directory, these tests are the TDD tests that we have not yet implemented.




Best Practices
---------------

### Feel Free to Write Your Own Scripts - put them in `put_temp_files_here`

sbcl ( with --script or with --load flag ) is super handy for writing quick one-off scripts.
There are several useful ones for checking syntax, parentheses and more in the `scripts` directory.

But, for most intermediate work, as well as log files,  use the `put_temp_files_here` directory so as to not pollute the repo. 


### APPEND? : yes!  PATCH? : no
Common Lisp has a super power: late binding and dynamic redefinition. We leverage that.
Rather than trying to patch the .lisp src files and having to deal with Windows escaping and parentheses matching, for any function you want to update, APPEND a full new definition at the end
of one of the overlay files. There is one for each package: `overlays/crisp-compiler-overlay.lisp`, 
`overlays/crisp-language-overlay.lisp` and `overlays/crisp-llvm-bindings-overlay.lisp`. When the 
compiler is built, those "late" fixed definitions will be seen and take the place of the buggy ones.

NOTE: I will apply these fixes when we are done with the feature or bug fix.  Add a comment before each append telling me which file it should go to:

```
;; src/compiler.lisp
(defun something-yadda () ...)
```

ALSO IMPORTANT: do NOT patch the overlays. Just APPEND. Works.

LASTLY: this can't be used for macros or structs. In those cases, we may have to patch. The simplest 
and safest is just write the macro to a file and ask me to patch it.  We are a team.



### Log Liberally
You are pretty good at this, but just as a reminder, with Log4CL we can log liberally and without consequence. 
That logging is very handy when it comes to debugging.  So let's use it freely.

BUT NOTE: please use log4cl, do NOT just (format T ...) or (format *error-output* ...), use log4cl so we can control the logging level.

### Doc Strings
Second, Common Lisp Doc Strings are great. Let's try to make sure every function has one.  Those doc strings
end up in the @crisp/docs/reference.md file, so they help YOU understand things as well.

### TDD
I usually prefer that we follow a Test Driven Development (TDD) approach.  The tests are in the @crisp/tests/specs/ directory, organized by feature/endeavor.  We will implement them one at a time, until the feature is complete.

### Definition of Done
I made a little document @crisp/plan/definition-of-done.md that lists the little tasks we
shouldn't overlook as we finish any given feature.

### Avoid 'forward-only'
For our TDD tests if there is a non-differentiable kernel, we have two options to prevent it
from failing the --differentiate pass of the spec runner.  We can add a `forward-only` declaration
to the kernel, or we can use a directive: `;; SKIP-WITH[--differentiate]: "reason"`

Let's try to make the practice of NOT using `forward-only` and instead use the directive.
Also, the A|D system is quite powerful now and has far fewer exceptions than in the past, most
kernels SHOULD be differentiable. 

### Don't forget to test 'on metal'
Most of the TDD tests just need to compile correctly and many have additional validators that
can be called. But for some endeavors it's important to remember to test on actual GPU hardware.
Use the `TEST-HOIST[L0]` and `HOIST-EXPECT` for that.
Additionally, the `--differentiate` pass can ALSO be tested on metal using the `VERIFY-AUTODIFF` directive (and its expectation)


Exploiting Lisp MCP
-------------------
Via MCP (see below for exact instructions) you are able to connect directly to SBCL. This means
you can use the Common Lisp REPL yourself.  The instructions for users in @crisp/INSTALL.md could be used BY YOU.

For example:
```
(push *default-pathname-defaults* asdf:*central-registry*)
(ql:quickload "crisp")
(in-package crisp.compiler)
(initialize-compiler :log-level :debug)

;; now you can call any function in the compiler!!
(compile-crisp-form-to-ir-string '(def-function wow () (declare (return-type int)) 7) :debug-p T)

And, even better, you can REDEFINE any function of the compiler!!  Add breakpoints, step through code, etc.
```


This is a super power.  You could do the following:


```
(apropos "print-compiler-error") ;; get a list of all functions and symbols etc that have "print-compiler-error" in their name

(describe #'crisp.main::print-compiler-error)  ;; get a description of something
#<FUNCTION CRISP.MAIN::PRINT-COMPILER-ERROR>
  [compiled function]
Lambda-list: (C FILENAME)
Derived type: (FUNCTION (T T) (VALUES NULL &OPTIONAL))
Documentation:
  Prints a formatted compiler error to *error-output*.
Source file: c:/Users/cperk/Documents/crisp/src/main.lisp
NIL


(require :sb-instrospect)  ;; watch next

(sb-introspect:find-definition-source #'crisp.main::print-compiler-error)
#S(DEFINITION-SOURCE
   :PATHNAME c:/Users/cperk/Documents/crisp/src/main.lisp
   :FORM-PATH (1)
   :FORM-NUMBER 0
   :CHARACTER-OFFSET 219
   :FILE-WRITE-DATE 3978220695
   :PLIST NIL
   :DESCRIPTION NIL)

;; why would you ever use Select-String? (grep is not an option as we are on Windows).
;; you could use Lisp to open a stream to that file, go to that position and (read strm).
;; and if you really want the "text" , check file position after. 
;; but is that really necessary? super power!!
```

The above only scratches the surface.  You can call a function, evaluate a form, ADD BREAKPOINTS. 

### MCP and LLVM-C.dll conflict

As I cannot use MCP myself, I am not sure this conflict will affect you. BUT, when I use SBCL directly 
and load the compiler (like above) then because the LLVM-C.dll is loaded, if I go to another terminal and
try to build the compiler, it fails.  I have to close SBCL and then I can build.

You _might_ experience the same thing. Just be aware. 


Connecting to Lisp MCP & Safe Loading 
---------------------------------------------------
1. **Connection**:
   - The MCP server is configured in `mcp.json` to launch automatically via stdio transport using `start-mcp.bat`.
   - **Do not** manually run `start-mcp.bat` or `launch-mcp.bat` unless debugging a connection failure.
   - If connection is lost, reload the AntiGravity window to restart the server process.

2. **Safe Loading ("The Silent Treatment")**:
   - **Risk**: The JSON-RPC protocol over stdio corrupts instantly if any Lisp code prints to `*standard-output*` (e.g., Quicklisp compilation logs).
   - **Solution**: When loading heavy systems like `:crisp` or running verbose commands, you **MUST** capture or silence stdout locally.
   - **Snippet**:
     ```lisp
     (with-output-to-string (*standard-output*)
       (let ((*trace-output* *standard-output*)
             (*debug-io* *standard-output*))
         (ql:quickload :crisp)))
     ```
   - **Failure Mode**: If you forget this wrapper, the connection will drop with an "invalid character" error, requiring a full window reload.


Working Together
----------------

When we are working together, please do not rush to make patches.  I prefer for us to 
discuss and agree on decisions before implementing them. When I am ready for a patch
I will request one.  Furthermore, sometimes if I do not accept a patch, then your mental
model can get out of sync, so let's avoid that.

Similarly, when we encounter bugs, do not rush to patch just because "you know" the problem.
First, let's come up with some theories about the issue, and how we can test or verify 
those theories before proceeding with a patch.  Measure twice, cut once.

If ever you need more information, a file that has been added to the context, for example, 
don't hesitate to ask. I'm happy to get what you need. Including stacktraces, etc.

We have a lot of logging in this project, and I expect there will be more. We are using log4cl
which makes it easy to turn it on and off. Don't remove the logging for aesthetic reasons. 
And definitely don't remove logging as part of a patch to fix something. That is not
correct or professional. We wait to verify the fix before adjusting logging.


Thanks again for your help. 

Chris






