# Runtime Strings 📝


Runtime strings are a completely different animal. 

The only runtime strings Crisp supports are the ones output into the debug logging
buffer. That buffer is written into by `r-t-output`, `r-t-assert`, `die` and their variants. 

The buffer is a not a buffer of ASCII characters. It is a buffer of bytes, organized in groups of four ( `uint32_t` ), endianess determined by the host platform.  The buffer has a simple format. 
It is a series of packets, each like so.
`[IDENTIFIER][LENGTH][ x1 ][ x2] ..[xN]`   
Where `N` is the value in `LENGTH`.  

`IDENTIFIER` is a number, and in the accompanying metadata there is a table with 
each identifier and its matching format string and params, from which the final string
can be constructed.
```
{
  "id": 123,
  "format_string": "hello: % % % there",
  "params": [
    {"name": "i", "type": "int32"},
    {"name": "j", "type": "float32"},
    {"name": "k", "type": "uint64"}
  ]
}
``` 

Crisp comes with scripts that can recombine these, and a small standalone tool as well.

This formulation for string handling is analagous to the OSL "Journal Buffer" system. The
hope is that their performance penalty is minimal which will encourage use.

NOTE: Under consideration is just outputting full strings into a uchar buffer. That is simple
and no doubt attractive to Crisp users. This issue is that doing so can easily have 
a HUGE impact on performance. On the plus side, uchar 
output would be easily to stream out, which means it would be composable with other 
tools (like grep and tail). This might show up with a `--logging-output=string` type of 
formulation. 



