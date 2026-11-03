In these next few endeavors we are going to add support for Quantized Integers and Microfloat Blocks.

Note that this endeavor is "205", which gives us a few slots before it, we might have to have some preliminary endeavors precede it. So the first step is to plan that out.

In ./docs/ideal_001.md lines 9389 to 9872 is the current design for quantized integers.

Note that the current design implies `def-type-function` ( ideal_001.md lines 1695 to 1715 ) which is not realized yet.  It also implies the need for nominal typing. 

But also note that the design for Quantized Integers is a little old. It was done BEFORE we added records  def-record, which are fully realized (starting with 010) AND have full support of nominal and branded types via derived and branded types ( 031, 033, 035 ).

So I'm wondering if
a) we can realize the design for quantized integers and microfloat blocks via def-record and the current derived type system.
b) if the API, as designed today, mightn't deserve to be updated.
c) Do we need to realize def-type-function now?
