# Logging and Debugging 📝


> Overengineer much?
>
> (asked of Author)

When a kernel is running on a GPU it is often on a different device, with a completely different memory and addressing system and no 
access to stdout or the file system. This makes debugging and logging challenging. Crisp attempts to assist with two different systems:
 - compile-time messaging, so that the compiler can be directed to output messages and information. 
 - side channel logging at runtime.  This has to be elected when compiling your kernel and the hoisting/enqueue code has to participate as well.


