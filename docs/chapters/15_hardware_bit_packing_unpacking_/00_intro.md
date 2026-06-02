# Hardware Bit Packing / Unpacking ✅


Modern GPU hardware has built-in intrinsic functions which can quickly pack and unpack values out
of bitfields, sometimes with a loss of accuracy. If you expect to read or store these values
from a vector or tensor exactly once then the best practice would be use Crisp derived types and 
custom getter/setter functions. See the example for `op-pack-11` below.

