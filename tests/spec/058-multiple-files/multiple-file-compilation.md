
Going to extend the compiler so it can support compiling multiple files at one time.

```
$ crisp-compile.exe aten-utils.crisp my-kernel.crisp
```

Basically, the compiler just reads in all the .crisp files (in order) and compiles as if they had been one file. In the future, this may become more advanced as we introduce "(declare entrypoint)" for library functions and the like (and dead code elimination).  But for now it's pretty simple.

Note that the file A might contain defmacro used by file B.  So we need to handle that.

Also note that the error/debug reporting doesn't use filename-lineno , it instead names the parent function/form and then has a #(0 2 3 0) vector that leads down through the branches to the leaf where
the error occurred. While not perfect, this system maps pretty well to Lisp because of the macro AST transformations etc.  But we need to make sure that these indeces aren't across ALL the files being compiled.   

By default, Crisp compiles multi-pass. But it does support a --single-pass flag


I have created some test .crisp files. By themselves, they mostly won't compile correctly. The intention is that 01-library.crisp is paired with each of the "app" tests.  So `$ crisp-compile.exe 01-library.crisp 11-app-basic.crisp` , `$ crisp-compile.exe 01-library.crisp 13-app-template.crisp` , etc.  We can use a `xxxx.unit.lisp` to coordinate that.
