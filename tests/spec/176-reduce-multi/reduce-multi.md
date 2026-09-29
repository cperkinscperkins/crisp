I'd like to add support for "multiple value reduction" to Crisp, as well as the "easy" `grid-reduce!` form. 


- [ ] review current design docs. I have updated tests\spec\175-reductions\reductions-excerpt.md
      with the latest
- - [ ] are the "possible implementations" correct? Close enough? SHould they be dropped?
- - [ ] is `grid-reduce` with it's reliance on a strategy enum and implicit side channel arg support feasible? Well designed?
- FEASIBLE

|                 | reduce-warp | reduce-workgroup | grid-reduce! |
| ----------------| ------------| -----------------|--------------|
| single variable | OK          |  OK              |              |
| indepdendent    |             |                  |              |
| dependent       |             |                  |              |
| ----------------| ------------| -----------------|--------------|




- [ ] fix docs: For most reductions,  return-vec should be return-cell and doesn't need `single-result` language nor "vector of size 1".


- [ ] type-min and type-max TDD tests
- [ ] type-min and type-max implementation 
- [ ] type-min and type-max documentation (where should it go?)
- 


- [ ] TDD tests for elided &key arguments to existing Phase 1 and Phase 2 reductions. 
- in theory, something like this should work already today:
  `... &key (someKey (make-scratch-vector :num-workgroups))`
- - [ ]  Make sure defaults are working right. 
- - [ ] update documentation
- [ ] should we audit the .metacrisp ? They effect the kernel signature a lot.
- [ ] and the hoisted code? For L0 and CUDA? 

- [ ] TDD tests for "Easy" grid-reduce!.  
- [ ] including autodiff?

- [ ] TDD tests for the three independent variants
- [ ] including autodiff?

- [ ] TDD tests for three dependent variants
- [ ] including autodiff?

