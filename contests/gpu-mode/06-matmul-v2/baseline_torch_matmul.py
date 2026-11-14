#!POPCORN leaderboard matmul_v2
# Runner control (no Crisp): torch.matmul.  Used to tell an L4 runner timeout from a Crisp kernel hang.
import torch
from task import input_t, output_t


def custom_kernel(data: input_t) -> output_t:
    a, b, c = data
    c.copy_(torch.matmul(a, b))
    return c
