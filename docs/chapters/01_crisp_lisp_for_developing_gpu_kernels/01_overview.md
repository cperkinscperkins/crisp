# Overview


GPUs with their lockstep parallelism are absolutely amazing at delivering blistering performance for certain types of algorithms. But they are also brittle and finicky. Data coherence, occupancy, branch divergence, register spilling, workgroup and warp coordination, and much more all conspire to make reaching optimal performance tricky. Heck, just basic _correctness_ is tricky. My thought was that the language and tooling should guide users away from mistakes, away from sub-optimal decisions and towards correctness and optimal performance, without nannying. I didn't want to make a new language. I really didn't. I  was just collecting some ideas that I couldn't figure out how to realize and Crisp is the shape they took.

Crisp is a Lisp for writing GPU kernels.  It is quite different than existing solutions and quite difficult to easily sum up in a paragraph or two. Crisp gives particular attention to surfacing common GPU memes as directly usable language constructs. The Crisp compiler can compile kernels FAST and it supports auto differentiation. It is itself invokable from Python or from C/C++. Through its C API a kernel held in a string is compiled, loaded and launched in a fraction of a second, so a kernel can be specialized to the shapes and constants of the moment. This means Crisp is a great solution for doing runtime compilation.   Kernels written in Crisp can be compiled to both PTX and SPIR-V, to support NVidia and Intel hardware.   There is no Crisp runtime library to link against, instead the compiler can also generate "hoisting" example code. This is .cu / .cpp code that uses CUDA / LevelZero to load, enqueue, and read back results for the specified kernel. Python hoisting is planned.

 The quickest way to try it is the [Colab notebook](https://colab.research.google.com/github/cperkinscperkins/crisp/blob/main/notebooks/crisp-gpu-intro.ipynb), which runs on a free T4. 

Crisp code is often portable, but portability for its own sake is not a primary goal. The primary goals for Crisp are performance, correctness and expressiveness. Crisp aims to bring GPU programming memes and concerns closer to the programmer, and in so doing guide the user towards performance and correctness and away from suboptimal patterns.   


