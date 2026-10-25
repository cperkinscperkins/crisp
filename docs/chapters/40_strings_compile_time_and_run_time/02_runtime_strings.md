# Runtime Strings 📝


Runtime strings are a completely different animal. 

The only runtime strings Crisp supports are the ones output into the log
(see [The Log](#the-log)). The log is written into by `r-t-output`, `r-t-assert`, `die` and their variants. 

The log is not a buffer of characters.  It is a sequence of packets of 32-bit words (see
[The Log](#the-log)): a site id, the writer's group and local ids, and the message's runtime
values.  Everything known at compile time -- the file, the line, the strings, and the type of each
value -- is in the metadata's site table, and the host rebuilds the text from it:
```
(:log-sites :record "__crisp_log" :capacity-words 1048572
  :sites ((1 "stencil.crisp" 42 ("reached midpoint" :int))))
```
The generated launchers do this and print the result.

This formulation for string handling is analagous to the OSL "Journal Buffer" system. The
hope is that their performance penalty is minimal which will encourage use.

NOTE: Under consideration is just outputting full strings into a uchar buffer. That is simple
and no doubt attractive to Crisp users. This issue is that doing so can easily have 
a HUGE impact on performance. On the plus side, uchar 
output would be easily to stream out, which means it would be composable with other 
tools (like grep and tail). This might show up with a `--logging-output=string` type of 
formulation. 



