# `exclusive-scan-workgroup` 📝

The purpose of `exclusive-scan-workgroup` is to, for each element in a vector, calculate the sum of all the elements
that came before it. This is an extremely useful routine. If the activity if "finding matches" then the input vector
might be a vector of 0s and 1s (where 1 represents a "match"). 
But other times the vector is the "number of matches" for each of the workgroups or warps, in this case 
`exclusive-scan-workgroup` lets us transform that into a running total of all matches (ie `#(3 2 7 1) => #(3 5 12 13)`).

Since this only works on the scope of one workgroup, the input vector cannot be longer than the kernel work size.

`exclusive-scan-workgroup` modifies the vector in place.  It returns the final sum of the scan.

It works in two passes, first "sweeping up" the values with an increasing step size, and then "sweeping down" the results.
This "sweep up" "sweep down" will be more important once we want to start perform these scans on the really big vectors, vectors
that are bigger than just one workgroup.  

#### Finding Matches Example

Let's assume there a mere 6 threads in a workgroup. Our algorithm finds some match or miss and
records in a vector, each match or miss stored at the local id of whatever thread did the check.
Our vector has two states, the "input" state before `exclusive-scan-workgroup` is run, and its modified output state
once `exclusive-scan-workgroup` is complete. 

`(exclusive-scan-workgroup match-vector)`

```
Input:  #(0 1 0 1 1 0)
Output: #(0 0 1 1 2 3)
```
If you look at the output, the value at each "match" position tells you exactly how many matches came before it:
  Thread 1: Its output is 0. There were 0 matches before it.
  Thread 3: Its output is 1. There was 1 match before it (at index 1).
  Thread 4: Its output is 2. There were 2 matches before it (at indices 1 and 3).
This output gives each "winner" its unique, zero-based local index (0, 1, 2)


