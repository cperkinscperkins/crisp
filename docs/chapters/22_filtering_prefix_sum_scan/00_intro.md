# Filtering / Prefix-Sum Scan


A common activity on the GPU is to "find all matches".  Crisp has several macros and functions that
can help with that.  Most prominent is the support for "prefix-sum scans" such as "exclusive scan" and
"inclusive scan".  
In these operations, a vector that consists of matches (1) and misses (0) is converted
into a vector that counts "how many before".  And a vector in "prefix sum scan" format is easy to 
then parse to a compact short list of results.  The "word count" example below illustrates.

