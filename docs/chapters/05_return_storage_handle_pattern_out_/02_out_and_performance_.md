# `&out` and performance ✅

For any kernel, when `&out` is used then the "other" parameters not designated as output are
considiered as read-only input candidates. You can read and write to those parameters, if you wish, BUT if you forego write operations to them and honor a read-only contract, then the optimizer will be better able to work its magic and improve your kernel performance. In other words, for maximum performance use `&out` to designate your kernel output parameters and only write to those, never to any others.


