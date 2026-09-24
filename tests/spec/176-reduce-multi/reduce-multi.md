I'd like to add support for "multiple value reduction" to Crisp, as well as the "easy" `grid-reduce` form. 


- [ ] review current design docs. I have updated tests\spec\175-reductions\reductions-excerpt.md
      with the latest
- - [ ] are the "possible implementations" correct? Close enough? SHould they be dropped?
- - [ ] is `grid-reduce` with it's reliance on a strategy enum and implicit side channel arg support feasible? Well designed?
- - FEASIBLE:
- - [ ] `reduce-warp-multi`
- - [ ] `reduce-workgroup-multi`
- - [ ] `reduce-grid-multi`
- - [ ] `reduce-vec`



- [ ] TDD tests for elided &key arguments to existing Phase 1 and Phase 2 reductions.  Make sure defaults are working right. 
- [ ] should we audit the .metacrisp ? They effect the kernel signature a lot.
- [ ] and the hoisted code? For L0 and CUDA? 

- [ ] TDD tests for "Easy" grid-reduce.  
- [ ] including autodiff?

- [ ] TDD tests for reduce-warp-multi  and reduce-workgroup-multi
- [ ] TDD tests for reduce-grid-multi
- [ ] including autodiff?

