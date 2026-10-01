# Hardware Profiles ✅


`--ir-target`, when set to `ptx` or `spv` tells the compiler the IR target, which will usually be `ptx` for NVidia hardware and `spv` for Intel (and possibly others).  When compiling a kernel that is often enough, nothing more is needed.  But for some capabilties and or optimizations, the  `--ir-target-arch` flag can be used to further inform about the exact architecutre (like `sm_80` or `xe2`).  But for absolutely maximum performance optimizations, the compiler can be given specific bounds and capabilities of a targeted hardware and then it can tailor to those.  These "specific bounds and capabilities" are called a "hardware profile".

Hardware profiles are recommended, but they are always optional. 

The Crisp compiler already knows about some hardware profiles. Those are listed below and their name alone as a flag or `:profile` value is sufficient to leverage them. But if Crisp doesn't have the exact profile for your hardware defined already, it is easy to provide it with `def-hardware-profile`.

Note that a hardware profile says nothing about that actual architecture. It may seem strange, but to the Crisp compiler these are orthogonal concerns. Note that this means that Crisp can be employed for certain types of micro-optimizations or experiments. If you know that when your kernel runs, the GPU will be already partially employed running something else, then use a custom shrunken hardware profile to optimize for the capabilities that WILL be available. This avoids the "Empty Room Fallacy" that ensnares other GPU toolchains.

