# LayerNorm CUDA Kernels

This directory contains the CUDA code for the kernels
described in the
[LayerNorm Kernel](https://github.com/VectorInstitute/ai-pocket-reference/blob/main/books/compute/src/cuda/kernels/layernorm_forward.md)
pocket reference.

These kernels are borrowed from the
[llm.c](https://github.com/karpathy/llm.c/tree/master/dev/cuda)
repository and modified to include additional comments for explanation.

## Compile kernel

```bash
nvcc --use_fast_math -lcublas -lcublasLt layernorm_forward.cu -o layernorm_forward
```

## Run kernel

```bash
./layernorm_forward <kernel_num>
```
