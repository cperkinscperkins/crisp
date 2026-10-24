# Logging and Debugging 📝


> Overengineer much?
>
> (asked of Author)
>
> Yes.  This section used to be three times longer.

When a kernel is running on a GPU it is on a different device, with its own memory, and no
access to stdout or the file system. Crisp offers two kinds of help:
 - compile-time messaging, so the compiler can be told to print things while it compiles;
 - runtime asserts, `die`, and a logging side channel.  You opt into these when compiling,
   and the hoisting code has to take part too.

