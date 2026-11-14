#!POPCORN leaderboard sort_v2
# Runner control (no Crisp): torch.sort.  Used to tell a B200 runner timeout from a Crisp kernel hang.
import torch
from task import input_t, output_t


def custom_kernel(data: input_t) -> output_t:
    x, out = data
    out.copy_(torch.sort(x).values)
    return out
