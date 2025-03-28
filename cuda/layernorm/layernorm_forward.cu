#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include <assert.h>
#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
#include "common.h"


// GPT-2 layernorm forward pass - CPU implementation
void layernorm_forward_cpu(
    float* out, float* mean, float* rstd,
    const float* inp, const float* weight, const float* bias,
    int B, int T, int C
) {
    float eps = 1e-5f;

    for (int b = 0; b < B; b++) {
        for (int t = 0; t < T; t++) {
            // seek to the input position inp[b,t,:]
            const float* x = inp + b * T * C + t * C;

            // calculate the mean
            float m = 0.0f;
            for (int i = 0; i < C; i++) {
                m += x[i];
            }
            m = m/C;

            // calculate the variance (without any bias correction)
            float v = 0.0f;
            for (int i = 0; i < C; i++) {
                float xshift = x[i] - m;
                v += xshift * xshift;
            }
            v = v/C;

            // calculate the rstd
            float s = 1.0f / sqrtf(v + eps);

            // seek to the output position in out[b,t,:]
            float* out_bt = out + b * T * C + t * C;
            for (int i = 0; i < C; i++) {
                float n = (s * (x[i] - m)); // normalized output
                float o = n * weight[i] + bias[i]; // scale and shift it
                out_bt[i] = o; // write
            }

            // cache the mean and rstd for the backward pass later
            mean[b * T + t] = m;
            rstd[b * T + t] = s;
        }

    }
}


// GPU kernels
// ---------------------------------------------------------------------------

// Kernel 1
// Copy of the CPU implementation and parallelizing over B and T
// Hence each thread is responsible for one segment of size C over which the statistics are computed
__global__ void layernorm_forward_kernel1(
    float* out, float* mean, float* rstd,
    const float* inp, const float* weight, const float* bias,
    int N, int C
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    float eps = 1.0e-5f;

    if (idx < N) {
        // Go to the start index of the input segment for this thread, inp[idx, :]
        const float* x = inp + idx * C;

        // Compute mean
        float m = 0.0f;
        for (int i = 0; i < C; i++) {
            m += x[i];
        }
        m /= C;

        // Compute variance (without any bias correction)
        float v = 0.0f;
        for (int i = 0; i < C; i++) {
            float diff = x[i] - m;
            v += diff * diff;
        }
        v /= C;

        // Compute rstd
        float r = 1.0f / sqrt(v + eps);

        // Compute output
        // Go to the start index of the output segment for this thread, out[idx, :]
        float* y = out + idx * C;
        for (int i = 0; i < C; i++) {
            float o_prime = (x[i] - m) * r; // normalized output
            float o = o_prime * weight[i] + bias[i]; // scale and shift
            y[i] = o;
        }

        // Store mean and rstd for backward pass
        mean[idx] = m;
        rstd[idx] = r;
    }
}

void layernorm_forward1(
    float* out, float* mean, float* rstd,
    const float* inp, const float* weight, const float* bias,
    int B, int T, int C,
    const int block_size
) {
    // 1D grid and 1D block
    const int N = B * T;
    const int grid_size = ceil_div(N, block_size);
    layernorm_forward_kernel1<<<grid_size, block_size>>>(out, mean, rstd, inp, weight, bias, N, C);
    cudaCheck(cudaGetLastError());
}


// Kernel 2
// Separate kernels for mean, rstd and normalization
// mean and rstd kernels use the concept from "Puzzle 13 - Axis Sum"
// - each block is responsible for one segment of size C instead of each thread
// - use shared memory of size block_size to store the partial sums
// For the normalization kernel, each thread corresponds to one output element
__global__ void mean_kernel(
    float* mean,
    const float* inp,
    int N, int C,
    int block_size
) {
    extern __shared__ float shared[];
    int idx = blockIdx.x; // range [0, B*T)
    int tid = threadIdx.x; // range [0, block_size)
    const float* x = inp + idx * C;
    // thread coarsening
    float sum = 0.0f;
    for (int i = tid; i < C; i += block_size) {
        sum += x[i];
    }
    shared[tid] = sum;
    __syncthreads();
    // reductions
    for (int stride = block_size / 2; stride >= 1; stride /= 2) {
        __syncthreads();
        if (tid < stride) {
            shared[tid] += shared[tid + stride];
        }
    }
    // write the final result (at thread 0) to global memory
    if (tid == 0) {
        mean[idx] = shared[0] / C;
    }
}

__global__ void rstd_kernel(
    float* rstd,
    const float* inp, const float* mean,
    int N, int C,
    int block_size
) {
    extern __shared__ float shared[];
    int idx = blockIdx.x; // range [0, B*T)
    int tid = threadIdx.x; // range [0, block_size)
    const float* x = inp + idx * C;
    float m = mean[idx];
    // thread coarsening
    float sum = 0.0f;
    for (int i = tid; i < C; i += block_size) {
        float diff = x[i] - m;
        sum += diff * diff;
    }
    shared[tid] = sum;
    __syncthreads();
    // reductions
    for (int stride = block_size / 2; stride >= 1; stride /= 2) {
        __syncthreads();
        if (tid < stride) {
            shared[tid] += shared[tid + stride];
        }
    }
    // write the final result (at thread 0) to global memory
    if (tid == 0) {
        rstd[idx] = 1.0f / sqrtf(shared[0] / C + 1e-5f);
    }
}

__global__ void normalization_kernel(
    float* out,
    const float* inp, float* mean, float* rstd,
    const float* weight, const float* bias,
    int B, int T, int C
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    int bt = idx / C;
    int c = idx % C;

    float m = mean[bt];
    float s = rstd[bt];
    float xi = inp[idx];
    float n = s * (xi - m);
    float o = n * weight[c] + bias[c];

    out[idx] = o;
}

void layernorm_forward2(
    float* out, float* mean, float* rstd,
    const float* inp, const float* weight, const float* bias,
    int B, int T, int C,
    const int block_size
) {
    int N = B * T;

    // in mean and rstd, threads cooperate within blocks via reductions
    mean_kernel<<<N, block_size, block_size * sizeof(float)>>>(mean, inp, N, C, block_size);
    cudaCheck(cudaGetLastError());
    rstd_kernel<<<N, block_size, block_size * sizeof(float)>>>(rstd, inp, mean, N, C, block_size);
    cudaCheck(cudaGetLastError());

    // in the normalization, everything just gets flattened out
    const int block_size2 = 256;
    const int grid_size = ceil_div(B * T * C, block_size2);
    normalization_kernel<<<grid_size, block_size2>>>(out, inp, mean, rstd, weight, bias, B, T, C);
    cudaCheck(cudaGetLastError());
}


// Kernel 3
// Uses co-operative groups
// - makes each warp group responsible for one segment of size C, instead of each block
// - allows use of reduction methods (such as cg::reduce) defined for these groups
// Uses the __restrict__ keyword, allowing the compiler to benefit from reduced memory accesses and computations (but at the cost of increase in register pressure which can reduce occupancy). See more: https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#restrict
// Uses Cache Operators, .cs to limit cache pollution. See more: https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#cache-operators
__global__ void layernorm_forward_kernel3(
    float* __restrict__ out, float* __restrict__ mean, float* __restrict__ rstd,
    const float*  __restrict__ inp,
    const float*  __restrict__ weight, const float* __restrict__ bias,
    int N, int C
) {
    namespace cg = cooperative_groups;
    cg::thread_block block = cg::this_thread_block();
    cg::thread_block_tile<32> warp = cg::tiled_partition<32>(block);

    // meta_group_size is the number of warps in a block, and meta_group_rank is the warp index
    int idx = blockIdx.x * warp.meta_group_size() + warp.meta_group_rank();
    if(idx >= N) {
        return;
    }

    // the row of input that this group of threads is responsible for
    const float* x = inp + idx * C;

    // mean
    float sum = 0.0f;
    for (int i = warp.thread_rank(); i < C; i += warp.size()) {
        sum += x[i];
    }
    sum = cg::reduce(warp, sum, cg::plus<float>{});
    float m = sum / C;
    if(warp.thread_rank() == 0 && mean != nullptr) {
        __stcs(mean + idx, m);
    }

    // rstd
    sum = 0.0f;
    for (int i = warp.thread_rank(); i < C; i += warp.size()) {
        float diff = x[i] - m;
        sum += diff * diff;
    }
    sum = cg::reduce(warp, sum, cg::plus<float>{});
    float s = rsqrtf(sum / C + 1e-5f);
    if(warp.thread_rank() == 0 && rstd != nullptr) {
        __stcs(rstd + idx, s);
    }

    // final normalization and scaling by weight/bias
    float* o = out + idx * C;
    for (int c = warp.thread_rank(); c < C; c += warp.size()) {
    // load and store using the .cs "streaming" hint to the compiler,
    // indicating that this data will not be reused soon, and can be streamed through the caches
    // this allows the threads to get more cache-hits for the (shared) weight and bias parameters
        float n = s * (__ldcs(x+c) - m);
        __stcs(o+c, n * weight[c] + bias[c]);
    }
}

void layernorm_forward3(
    float* out, float* mean, float* rstd,
    const float* inp, const float* weight, const float* bias,
    int B, int T, int C,
    const int block_size
) {
    assert(block_size % 32 == 0);
    const int N = B * T;
    // Note how grid_size changes based on kernel
    const int grid_size = ceil_div(N * 32, block_size);
    layernorm_forward_kernel3<<<grid_size, block_size>>>(out, mean, rstd, inp, weight, bias, N, C);
    cudaCheck(cudaGetLastError());
}


// Kernel 4
// Same as Kernel 3 but uses var(x) == mean(x**2) - mean(x)**2
__global__ void layernorm_forward_kernel4(
    float* __restrict__ out, float* __restrict__ mean, float* __restrict__ rstd,
    const float*  __restrict__ inp,
    const float*  __restrict__ weight, const float* __restrict__ bias,
    int N, int C
) {
    namespace cg = cooperative_groups;
    cg::thread_block block = cg::this_thread_block();
    cg::thread_block_tile<32> warp = cg::tiled_partition<32>(block);

    int idx = blockIdx.x * warp.meta_group_size() + warp.meta_group_rank();
    if(idx >= N) {
        return;
    }

    // the row of input that this group of threads is responsible for
    const float* x = inp + idx * C;

    // thread coarsening through the row, reduce the sum in series
    float sum = 0.0; // stores sum(x)
    float sum2 = 0.0; // stores sum(x**2)
    for (int i = warp.thread_rank(); i < C; i += warp.size()) {
        float xi = x[i];
        sum += xi;
        sum2 += xi * xi;
    }
    // warp-level reduction at the end
    sum = cg::reduce(warp, sum, cg::plus<float>{}); // sum(x)
    sum2 = cg::reduce(warp, sum2, cg::plus<float>{}); // sum(x**2)
    sum /= C; // mean(x)
    sum2 /= C; // mean(x**2)

    // mean, var, rstd
    float m = sum;
    float var = sum2 - sum * sum;
    float s = rsqrtf(var + 1e-5f);

    // store the mean, no need to cache it
    if(warp.thread_rank() == 0 && mean != nullptr) {
        __stcs(mean + idx, m);
    }
    // store the rstd, no need to cache it
    if(warp.thread_rank() == 0 && rstd != nullptr) {
        __stcs(rstd + idx, s);
    }

    // final normalization and scaling by weight/bias
    float* o = out + idx * C;
    for (int c = warp.thread_rank(); c < C; c += warp.size()) {
        float n = s * (__ldcs(x+c) - m);
        __stcs(o+c, n * weight[c] + bias[c]);
    }
}

void layernorm_forward4(
    float* out, float* mean, float* rstd,
    const float* inp, const float* weight, const float* bias,
    int B, int T, int C,
    const int block_size
) {
    assert(block_size % 32 == 0);
    const int N = B * T;
    const int grid_size = ceil_div(N * 32, block_size);
    layernorm_forward_kernel4<<<grid_size, block_size>>>(out, mean, rstd, inp, weight, bias, N, C);
    cudaCheck(cudaGetLastError());
}


// Kernel 5
// Similar to Kernel 4, but in Kernel 5 we have each block doing one segment of C, in 2 stages
// 1. First at the warp level
// 2. And then at the block level
__global__ void layernorm_forward_kernel5(
    float* __restrict__ out, float* __restrict__ mean, float* __restrict__ rstd,
    const float*  __restrict__ inp,
    const float*  __restrict__ weight, const float* __restrict__ bias,
    int N, int C
) {
    namespace cg = cooperative_groups;
    cg::thread_block block = cg::this_thread_block();
    cg::thread_block_tile<32> warp = cg::tiled_partition<32>(block);

    __shared__ float shared_sum[32]; // block_size max is 1024 = 32 * 32 warps
    __shared__ float shared_sum2[32]; // warps will be writing into shared memory after warp-reduce

    int num_warps = blockDim.x / 32;
    int warp_id = threadIdx.x / 32;
    int lane_id = threadIdx.x % 32;
    int idx = blockIdx.x; // simply one block per row

    // the row of input that this group of threads is responsible for
    const float* x = inp + idx * C;

    // Stage 1
    // thread coarsening through the row, reduce the sum in series
    float thread_sum = 0.0; // stores sum(x)
    float thread_sum2 = 0.0; // stores sum(x**2)
    // for (int i = C + threadIdx.x - blockDim.x; i >= 0; i -= blockDim.x) {
    for (int i = threadIdx.x; i < C; i += blockDim.x) {
        float xi = x[i];
        thread_sum += xi;
        thread_sum2 += xi * xi;
    }
    // warp-level reduction
    float warp_sum = cg::reduce(warp, thread_sum, cg::plus<float>{}); // sum(x)
    float warp_sum2 = cg::reduce(warp, thread_sum2, cg::plus<float>{}); // sum(x**2)
    // store the warp-level reduction in shared memory
    // (we could have lane_id == 0 guard but not needed)
    shared_sum[warp_id] = warp_sum;
    shared_sum2[warp_id] = warp_sum2;
    __syncthreads();

    // Stage 2
    // load results from shared memory to threads, pad with zeros for threads that are out of bounds
    warp_sum = (lane_id < num_warps) ? shared_sum[lane_id] : 0.0f;
    warp_sum2 = (lane_id < num_warps) ? shared_sum2[lane_id] : 0.0f;
    // now reduce the warp-level reductions
    float block_sum = cg::reduce(warp, warp_sum, cg::plus<float>{}); // sum(x)
    float block_sum2 = cg::reduce(warp, warp_sum2, cg::plus<float>{}); // sum(x**2)

    // mean, var, rstd
    block_sum /= C; // mean(x)
    block_sum2 /= C; // mean(x**2)
    float m = block_sum;
    float var = block_sum2 - m * m;
    float s = rsqrtf(var + 1e-5f);
    // store the mean, no need to cache it
    if(threadIdx.x == 0 && mean != nullptr) {
        __stcs(mean + idx, m);
    }
    // store the rstd, no need to cache it
    if(threadIdx.x == 0 && rstd != nullptr) {
        __stcs(rstd + idx, s);
    }

    // final normalization and scaling by weight/bias
    float* o = out + idx * C;
    for (int i = threadIdx.x; i < C; i += blockDim.x) {
        float n = s * (__ldcs(x+i) - m);
        __stcs(o+i, n * weight[i] + bias[i]);
    }
}

void layernorm_forward5(
    float* out, float* mean, float* rstd,
    const float* inp, const float* weight, const float* bias,
    int B, int T, int C,
    const int block_size
) {
    assert(block_size % 32 == 0);
    assert(block_size <= 1024); // This is required since the size of shared memory is specified (at 32) in the kernel
    const int N = B * T;
    const int grid_size = N;
    layernorm_forward_kernel5<<<grid_size, block_size>>>(out, mean, rstd, inp, weight, bias, N, C);
    cudaCheck(cudaGetLastError());
}


// kernel version dispatch
void layernorm_forward(
    int kernel_num,
    float* out, float* mean, float* rstd,
    const float* inp, const float* weight, const float* bias,
    int B, int T, int C,
    const int block_size
) {
    switch (kernel_num) {
        case 1:
            layernorm_forward1(out, mean, rstd, inp, weight, bias, B, T, C, block_size);
            break;
        case 2:
            layernorm_forward2(out, mean, rstd, inp, weight, bias, B, T, C, block_size);
            break;
        case 3:
            layernorm_forward3(out, mean, rstd, inp, weight, bias, B, T, C, block_size);
            break;
        case 4:
            layernorm_forward4(out, mean, rstd, inp, weight, bias, B, T, C, block_size);
            break;
        case 5:
            layernorm_forward5(out, mean, rstd, inp, weight, bias, B, T, C, block_size);
            break;
        // case 6:
        //     layernorm_forward6(out, mean, rstd, inp, weight, bias, B, T, C, block_size);
        //     break;
        default:
            printf("Invalid kernel number\n");
            exit(1);
    }
}


int main(int argc, char **argv) {
    srand(0);

    int B = 8;
    int T = 1024;
    int C = 768;

    int deviceIdx = 0;
    cudaCheck(cudaSetDevice(deviceIdx));

    // create host memory of random numbers on CPU
    float* out = (float*)malloc(B * T * C * sizeof(float));
    float* mean = (float*)malloc(B * T * sizeof(float));
    float* rstd = (float*)malloc(B * T * sizeof(float));
    float* inp = make_random_float(B * T * C);
    float* weight = make_random_float(C);
    float* bias = make_random_float(C);

    // move to GPU
    // GPU vars
    float* d_out;
    float* d_mean;
    float* d_rstd;
    float* d_inp;
    float* d_weight;
    float* d_bias;
    // allocate GPU memory
    cudaCheck(cudaMalloc(&d_out, B * T * C * sizeof(float)));
    cudaCheck(cudaMalloc(&d_mean, B * T * sizeof(float)));
    cudaCheck(cudaMalloc(&d_rstd, B * T * sizeof(float)));
    cudaCheck(cudaMalloc(&d_inp, B * T * C * sizeof(float)));
    cudaCheck(cudaMalloc(&d_weight, C * sizeof(float)));
    cudaCheck(cudaMalloc(&d_bias, C * sizeof(float)));
    // copy to GPU
    cudaCheck(cudaMemcpy(d_inp, inp, B * T * C * sizeof(float), cudaMemcpyHostToDevice));
    cudaCheck(cudaMemcpy(d_weight, weight, C * sizeof(float), cudaMemcpyHostToDevice));
    cudaCheck(cudaMemcpy(d_bias, bias, C * sizeof(float), cudaMemcpyHostToDevice));

    // read kernel_num from command line
    int kernel_num = 1;
    if (argc > 1) {
        kernel_num = atoi(argv[1]);
    }
    printf("Using kernel %d\n", kernel_num);

    int block_sizes[] = {32, 64, 128, 256, 512, 1024};

    layernorm_forward_cpu(out, mean, rstd, inp, weight, bias, B, T, C);

    // check the correctness of the kernel at all block sizes
    for (int j = 0; j < sizeof(block_sizes) / sizeof(int); j++) {
        int block_size = block_sizes[j];
        printf("Checking block size %d.\n", block_size);

        layernorm_forward(kernel_num, d_out, d_mean, d_rstd, d_inp, d_weight, d_bias, B, T, C, block_size);

        validate_result(d_out, out, "out", B * T * C, 1e-5f);
        validate_result(d_mean, mean, "mean", B * T, 1e-5f);
        validate_result(d_rstd, rstd, "rstd", B * T, 1e-5f);
    }

    printf("All results match. Starting benchmarks.\n\n");

    // time the kernel at different block sizes
    for (int j = 0; j < sizeof(block_sizes) / sizeof(int); j++) {
        int block_size = block_sizes[j];

        int repeat_times = 2000;
        float elapsed_time = benchmark_kernel(repeat_times, layernorm_forward,
                                              kernel_num, d_out, d_mean, d_rstd, d_inp, d_weight, d_bias,
                                              B, T, C, block_size);

        // napkin math: estimate the memory bandwidth achieved
        // e.g. A100 40GB PCIe is advertised at 1,555GB/s
        long memory_ops = (2 * B * T * C) * 4; // *4 for float
        float memory_bandwidth = memory_ops / elapsed_time / 1e6;

        printf("block_size %4d | time %.4f ms | bandwidth %.2f GB/s\n", block_size, elapsed_time, memory_bandwidth);
    }

    // free memory
    free(out);
    free(mean);
    free(rstd);
    free(inp);
    free(weight);
    free(bias);
    cudaCheck(cudaFree(d_out));
    cudaCheck(cudaFree(d_mean));
    cudaCheck(cudaFree(d_rstd));
    cudaCheck(cudaFree(d_inp));
    cudaCheck(cudaFree(d_weight));
    cudaCheck(cudaFree(d_bias));

    return 0;
}
