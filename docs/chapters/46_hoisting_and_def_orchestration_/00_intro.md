# Hoisting and `def-orchestration` ⚠️


When compiling, you can elect to have the Crisp compiler output "hoisting" example code. 
This is example code in C++ or Python that demonstrates how to read in the binary file,
create a program object, get a kernel, allocate memory, enqueue memory, set kernel arguments,
enqueue and run the kernel, and retrieve any result data (`&out`) after. It is entirely
optional, but can be a useful feature for debugging or sanity checking.

By default every kernel defined in the .crisp files (or instance of `gen-KERNELNAME` if templated) will 
have this hoisting code output for it when generating hoisting code.

But oftentimes kernels aren't intended to be run in isolation. They are intended to be run in conjunction
with other kernels. `def-orchestration` is Crisp affordance for this, it lets you communicate in a 
simple fashion how one kernel is expected to run relative another. And with this information
Crisp can both generate better hoisting code for you AND perform evaluations of your kernels at compile-time
and warn or error if compatibility or use issues are detected.

