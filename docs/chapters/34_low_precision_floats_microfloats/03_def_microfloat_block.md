# def-microfloat-block ✅


```lisp
(def-microfloat-block mf-w :base fp4 :scale fp8-e4m3 :accum float :shape (16))
```

- `:base` is `fp4`, `fp8-e4m3` or `fp8-e5m2`.
- `:scale` is any microfloat format.
- `:accum` is `float`, for now.
- `:shape` is one positive block size in elements, and it must be even for `fp4`, whose codes share
  bytes.

It defines:

| Name | What it is |
|---|---|
| `mf-w` | The block type: a record of `codes` and `scales` |
| `make-mf-w` | `(make-mf-w :codes c :scales s)` |
| `mf-w-codes` | `(vector uchar ..)`, the packed codes.  `fp4` packs two codes per byte |
| `mf-w-scales` | `(vector fp8-e4m3 ..)`, one scale per block |
| `mf-w-floats` | `(vector float ..)`, for the unquantized data |
| `quantize-to-mf-w`, `dequantize-from-mf-w`, `fake-quant-mf-w` | See below |
| `(accum mf-w)`, `(base mf-w)`, `(scale mf-w)` | `float`, `fp4`, `fp8-e4m3` |

The three handle types are `:global` and `:compact`. `(to-float w i)` and `(~ w i)` work on a block (see
[element-wise access](#element-wise-access-)).

Conceptually, the block is:

```lisp
(def-record mf-w
  (codes  mf-w-codes)    ; packed: two fp4 codes per byte
  (scales mf-w-scales))  ; one fp8-e4m3 per block
```

and `real = scale * decode(code)`.

Just like the quantized types, different block types cannot be intermixed, even if they are configured
with identical parameters.

Everything `def-microfloat-block` generates is ordinary Crisp: plain `def-function`s that decode and
encode each format, so both backends get them and a kernel can call them. Each is exact, because every
step is an integer shift or a multiply by a power of two.

**A block lives inside a kernel.** A kernel takes the two handles and builds the block with `make-NAME`.
A block cannot be a kernel parameter, because what a host would pass for it is not defined, and the same
goes for any record that holds a handle. Functions and grid functions may take one.

```lisp
(def-microfloat-block mf-w :base fp4 :scale fp8-e4m3 :accum float :shape (16))

(def-kernel quant (x &out c s)
  (declare #'(mf-w-floats &out mf-w-codes mf-w-scales)
           (global-size :derive-from s :strategy :strided))   ; one thread per block
  (let ((w (make-mf-w :codes c :scales s)))
    (quantize-to-mf-w x w)))
```

Every handle holds whole blocks: the floats hold `16` times as many elements as the scales. This is not
checked yet, so a float handle shorter than the scales imply reads past its end.

Two-dimensional blocks (`:shape (4 4)`) are not supported yet 📝.

