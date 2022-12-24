/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#ifndef ONEFLOW_CORE_CUDA_LAYER_NORM_H_
#define ONEFLOW_CORE_CUDA_LAYER_NORM_H_

#ifdef WITH_ROCM
#include "hip/hip_runtime.h"
#include <hipcub/hipcub.hpp>
#else
#include <cub/cub.cuh>
#include <math_constants.h>
#endif

#include <assert.h>

namespace oneflow {

namespace cuda {

namespace layer_norm {

#ifdef WITH_ROCM
constexpr int kWarpSize = 64;
#else
constexpr int kWarpSize = 32;
#endif

template<typename T>
struct SumOp {
  __device__ __forceinline__ T operator()(const T& a, const T& b) const { return a + b; }
};

template<typename T>
struct MaxOp {
  __device__ __forceinline__ T operator()(const T& a, const T& b) const { return max(a, b); }
};

template<template<typename> class ReductionOp, typename T, int thread_group_width = kWarpSize>
__inline__ __device__ T WarpAllReduce(T val) {
  for (int mask = thread_group_width / 2; mask > 0; mask /= 2) {
#ifdef WITH_ROCM
    val = ReductionOp<T>()(val, __shfl_xor(val, mask, thread_group_width));
#else
    val = ReductionOp<T>()(val, __shfl_xor_sync(0xffffffff, val, mask, thread_group_width));
#endif
  }
  return val;
}

template<template<typename> class ReductionOp, typename T, int block_size>
__inline__ __device__ T BlockAllReduce(T val) {
#ifdef WITH_ROCM
  typedef hipcub::BlockReduce<T, block_size> BlockReduce;
#else
  typedef cub::BlockReduce<T, block_size> BlockReduce;
#endif
  __shared__ typename BlockReduce::TempStorage temp_storage;
  __shared__ T result_broadcast;
  T result = BlockReduce(temp_storage).Reduce(val, ReductionOp<T>());
  if (threadIdx.x == 0) { result_broadcast = result; }
  __syncthreads();
  return result_broadcast;
}

template<typename T>
__inline__ __device__ T Div(T a, T b);

template<>
__inline__ __device__ float Div<float>(float a, float b) {
#ifdef OF_LAYER_NORM_USE_FAST_MATH
  return __fdividef(a, b);
#else
  return a / b;
#endif
}

template<>
__inline__ __device__ double Div<double>(double a, double b) {
  return a / b;
}

template<typename T>
__inline__ __device__ T Rsqrt(T x);

template<>
__inline__ __device__ float Rsqrt<float>(float x) {
#ifdef OF_LAYER_NORM_USE_FAST_MATH
  return __frsqrt_rn(x);
#else
  return rsqrt(x);
#endif
}

template<>
__inline__ __device__ double Rsqrt<double>(double x) {
  return rsqrt(x);
}

template<class Func>
inline GPU(Error_t) GetNumBlocks(Func func, int64_t block_size, size_t dynamic_smem_size,
                                int64_t max_blocks, int64_t waves, int* num_blocks) {
  int dev;
  {
    GPU(Error_t) err = GPU(GetDevice)(&dev);
    if (err != GPU(Success)) { return err; }
  }
  int sm_count;
  {
    GPU(Error_t) err = GPU(DeviceGetAttribute)(&sm_count, GPUMultiProcessorCount, dev);
    if (err != GPU(Success)) { return err; }
  }
  int max_active_blocks;
  {
    GPU(Error_t) err = GPU(OccupancyMaxActiveBlocksPerMultiprocessor)(&max_active_blocks, func,
                                                                    block_size, dynamic_smem_size);
  }
  *num_blocks =
      std::max<int>(1, std::min<int64_t>(max_blocks, sm_count * max_active_blocks * waves));
  return GPU(Success);
}

template<typename T>
struct DefaultComputeType {
  using type = T;
};

template<>
struct DefaultComputeType<half> {
  using type = float;
};

#if CUDA_VERSION >= 11000
template<>
struct DefaultComputeType<nv_bfloat16> {
  using type = float;
};
#endif  // CUDA_VERSION >= 11000

template<typename T>
class HasCanPackAs {
  typedef char one;
  struct two {
    char x[2];
  };

  template<typename C>
  static one test(decltype(&C::CanPackAs));
  template<typename C>
  static two test(...);

 public:
  enum { value = sizeof(test<T>(0)) == sizeof(char) };
};

template<typename T>
typename std::enable_if<HasCanPackAs<T>::value == true, bool>::type CanPackAs(T t,
                                                                              size_t pack_size) {
  return t.CanPackAs(pack_size);
}

template<typename T>
typename std::enable_if<HasCanPackAs<T>::value == false, bool>::type CanPackAs(T t,
                                                                               size_t pack_size) {
  return true;
}

template<typename T, int N>
struct GetPackType {
  using type = typename std::aligned_storage<N * sizeof(T), N * sizeof(T)>::type;
};

template<typename T, int N>
using PackType = typename GetPackType<T, N>::type;

template<typename T, int N>
union Pack {
  static_assert(sizeof(PackType<T, N>) == sizeof(T) * N, "");
  __device__ Pack() {
    // do nothing
  }
  PackType<T, N> storage;
  T elem[N];
};

template<typename SRC, typename DST>
struct DirectLoad {
  using LoadType = DST;
  DirectLoad(const SRC* src, int64_t row_size) : src(src), row_size(row_size) {}
  template<int N>
  __device__ void load(DST* dst, int64_t row, int64_t col) const {
    Pack<SRC, N> pack;
    const int64_t offset = (row * row_size + col) / N;
    pack.storage = *(reinterpret_cast<const PackType<SRC, N>*>(src) + offset);
#pragma unroll
    for (int i = 0; i < N; ++i) { dst[i] = static_cast<DST>(pack.elem[i]); }
  }
  const SRC* src;
  int64_t row_size;
};

template<typename SRC, typename DST>
struct DirectStore {
  DirectStore(DST* dst, int64_t row_size) : dst(dst), row_size(row_size) {}
  template<int N>
  __device__ void store(const SRC* src, int64_t row, int64_t col) {
    Pack<DST, N> pack;
    const int64_t offset = (row * row_size + col) / N;
#pragma unroll
    for (int i = 0; i < N; ++i) { pack.elem[i] = static_cast<DST>(src[i]); }
    *(reinterpret_cast<PackType<DST, N>*>(dst) + offset) = pack.storage;
  }
  DST* dst;
  int64_t row_size;
};

template<typename T>
inline __device__ void WelfordCombine(T val, T* mean, T* m2, T* count) {
  // Use Welford Online algorithem to compute mean and variance
  // For more details you can refer to:
  // https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance#Welford's_online_algorithm
  *count += 1;
  T delta1 = val - *mean;
  *mean += Div(delta1, *count);
  T delta2 = val - *mean;
  *m2 += delta1 * delta2;
}

template<typename T>
inline __device__ void WelfordCombine(T b_mean, T b_m2, T b_count, T* mean, T* m2, T* count) {
  if (b_count == 0) { return; }
  T new_count = *count + b_count;
  T nb_over_n = Div(b_count, new_count);
  T delta = b_mean - *mean;
  *mean += delta * nb_over_n;
  *m2 += b_m2 + delta * delta * (*count) * nb_over_n;
  *count = new_count;
}

template<typename T, int thread_group_width = kWarpSize>
__inline__ __device__ void WelfordWarpReduce(T thread_mean, T thread_m2, T thread_count, T* mean,
                                             T* m2, T* count) {
  *mean = thread_mean;
  *m2 = thread_m2;
  *count = thread_count;
  for (int mask = thread_group_width / 2; mask > 0; mask /= 2) {
#ifdef WITH_ROCM
    T b_mean = __shfl_down(*mean, mask, thread_group_width);
    T b_m2 = __shfl_down(*m2, mask, thread_group_width);
    T b_count = __shfl_down(*count, mask, thread_group_width);
#else
    T b_mean = __shfl_down_sync(0xffffffff, *mean, mask, thread_group_width);
    T b_m2 = __shfl_down_sync(0xffffffff, *m2, mask, thread_group_width);
    T b_count = __shfl_down_sync(0xffffffff, *count, mask, thread_group_width);
#endif
    WelfordCombine(b_mean, b_m2, b_count, mean, m2, count);
  }
}

template<typename T, int thread_group_width = kWarpSize>
__inline__ __device__ void WelfordWarpAllReduce(T thread_mean, T thread_m2, T thread_count, T* mean,
                                                T* m2, T* count) {
  WelfordWarpReduce<T, thread_group_width>(thread_mean, thread_m2, thread_count, mean, m2, count);
#ifdef WITH_ROCM
  *mean = __shfl(*mean, 0, thread_group_width);
  *m2 = __shfl(*m2, 0, thread_group_width);
  *count = __shfl(*count, 0, thread_group_width);
#else
  *mean = __shfl_sync(0xffffffff, *mean, 0, thread_group_width);
  *m2 = __shfl_sync(0xffffffff, *m2, 0, thread_group_width);
  *count = __shfl_sync(0xffffffff, *count, 0, thread_group_width);
#endif
  
}

template<typename T>
__inline__ __device__ void WelfordBlockAllReduce(T thread_mean, T thread_m2, T thread_count,
                                                 T* result_mean, T* result_m2, T* result_count) {
  __shared__ T mean_shared[kWarpSize];
  __shared__ T m2_shared[kWarpSize];
  __shared__ T count_shared[kWarpSize];
  __shared__ T mean_result_broadcast;
  __shared__ T m2_result_broadcast;
  __shared__ T count_result_broadcast;
  const int lid = threadIdx.x % kWarpSize;
  const int wid = threadIdx.x / kWarpSize;
  T warp_mean = 0;
  T warp_m2 = 0;
  T warp_count = 0;
  WelfordWarpReduce(thread_mean, thread_m2, thread_count, &warp_mean, &warp_m2, &warp_count);
  __syncthreads();
  if (lid == 0) {
    mean_shared[wid] = warp_mean;
    m2_shared[wid] = warp_m2;
    count_shared[wid] = warp_count;
  }
  __syncthreads();
  if (wid == 0) {
    if (threadIdx.x < blockDim.x / kWarpSize) {
      warp_mean = mean_shared[lid];
      warp_m2 = m2_shared[lid];
      warp_count = count_shared[lid];
    } else {
      warp_mean = static_cast<T>(0);
      warp_m2 = static_cast<T>(0);
      warp_count = static_cast<T>(0);
    }
    #ifdef WITH_ROCM
__syncthreads();
#else
__syncwarp();
#endif
    T block_mean = 0;
    T block_m2 = 0;
    T block_count = 0;
    WelfordWarpReduce(warp_mean, warp_m2, warp_count, &block_mean, &block_m2, &block_count);
    if (lid == 0) {
      mean_result_broadcast = block_mean;
      m2_result_broadcast = block_m2;
      count_result_broadcast = block_count;
    }
  }
  __syncthreads();
  *result_mean = mean_result_broadcast;
  *result_m2 = m2_result_broadcast;
  *result_count = count_result_broadcast;
}

template<typename LOAD, typename STORE, typename ComputeType, int pack_size,
         int max_cols_per_thread, int min_cols_per_thread, int thread_group_width,
         int rows_per_access, bool padding>
__global__ void LayerNormWarpImpl(LOAD load, STORE store, const int64_t rows, const int64_t cols,
                                  const double epsilon, ComputeType* mean,
                                  ComputeType* inv_variance) {
  using LoadType = typename LOAD::LoadType;
  static_assert(max_cols_per_thread % pack_size == 0, "");
  static_assert(min_cols_per_thread % pack_size == 0, "");
  static_assert(thread_group_width <= kWarpSize, "");
  static_assert(kWarpSize % thread_group_width == 0, "");
  constexpr int max_num_packs = max_cols_per_thread / pack_size;
  constexpr int min_num_packs = min_cols_per_thread / pack_size;
  assert(cols <= max_cols_per_thread * thread_group_width);
  ComputeType buf[rows_per_access][max_cols_per_thread];
  const int64_t global_thread_group_id = blockIdx.x * blockDim.y + threadIdx.y;
  const int64_t num_global_thread_group = gridDim.x * blockDim.y;
  const int64_t lane_id = threadIdx.x;
  const int64_t step = num_global_thread_group * rows_per_access;
  for (int64_t row = global_thread_group_id * rows_per_access; row < rows; row += step) {
    ComputeType thread_mean[rows_per_access];
    ComputeType thread_m2[rows_per_access];
    ComputeType thread_count[rows_per_access];
#pragma unroll
    for (int row_id = 0; row_id < rows_per_access; ++row_id) {
      thread_mean[row_id] = 0;
      thread_m2[row_id] = 0;
      thread_count[row_id] = 0;
      ComputeType* row_buf = buf[row_id];
#pragma unroll
      for (int pack_id = 0; pack_id < min_num_packs; ++pack_id) {
        const int col = (pack_id * thread_group_width + lane_id) * pack_size;
        const int pack_offset = pack_id * pack_size;
        LoadType pack[pack_size];
        load.template load<pack_size>(pack, row + row_id, col);
#pragma unroll
        for (int i = 0; i < pack_size; ++i) {
          row_buf[pack_offset + i] = static_cast<ComputeType>(pack[i]);
          WelfordCombine(row_buf[pack_offset + i], thread_mean + row_id, thread_m2 + row_id,
                         thread_count + row_id);
        }
      }
      for (int pack_id = min_num_packs; pack_id < max_num_packs; ++pack_id) {
        const int col = (pack_id * thread_group_width + lane_id) * pack_size;
        const int pack_offset = pack_id * pack_size;
        if (!padding || col < cols) {
          LoadType pack[pack_size];
          load.template load<pack_size>(pack, row + row_id, col);
#pragma unroll
          for (int i = 0; i < pack_size; ++i) {
            row_buf[pack_offset + i] = static_cast<ComputeType>(pack[i]);
            WelfordCombine(row_buf[pack_offset + i], thread_mean + row_id, thread_m2 + row_id,
                           thread_count + row_id);
          }
        } else {
#pragma unroll
          for (int i = 0; i < pack_size; ++i) { row_buf[pack_offset + i] = 0; }
        }
      }
    }
    ComputeType warp_mean[rows_per_access];
    ComputeType warp_m2[rows_per_access];
    ComputeType warp_count[rows_per_access];
#pragma unroll
    for (int row_id = 0; row_id < rows_per_access; ++row_id) {
      int global_row_id = row + row_id;
      ComputeType* row_buf = buf[row_id];
      WelfordWarpAllReduce<ComputeType, thread_group_width>(
          thread_mean[row_id], thread_m2[row_id], thread_count[row_id], warp_mean + row_id,
          warp_m2 + row_id, warp_count + row_id);
      ComputeType row_mean = warp_mean[row_id];
      ComputeType row_variance =
          max(Div(warp_m2[row_id], warp_count[row_id]), static_cast<ComputeType>(0.0));
      ComputeType row_inv_var = Rsqrt(row_variance + static_cast<ComputeType>(epsilon));
      if (lane_id == 0) {
        mean[global_row_id] = row_mean;
        inv_variance[global_row_id] = row_inv_var;
      }
#pragma unroll
      for (int i = 0; i < max_cols_per_thread; ++i) {
        row_buf[i] = (row_buf[i] - row_mean) * row_inv_var;
      }
#pragma unroll
      for (int i = 0; i < min_num_packs; ++i) {
        const int col = (i * thread_group_width + lane_id) * pack_size;
        store.template store<pack_size>(row_buf + i * pack_size, global_row_id, col);
      }
#pragma unroll
      for (int i = min_num_packs; i < max_num_packs; ++i) {
        const int col = (i * thread_group_width + lane_id) * pack_size;
        if (!padding || col < cols) {
          store.template store<pack_size>(row_buf + i * pack_size, global_row_id, col);
        }
      }
    }
  }
}

template<typename LOAD, typename STORE, typename ComputeType, int pack_size,
         int max_cols_per_thread, int min_cols_per_thread, int thread_group_width,
         int rows_per_access, bool padding>
inline GPU(Error_t) LaunchLayerNormWarpImpl(GPU(Stream_t) stream, LOAD load, STORE store,
                                           const int64_t rows, const int64_t cols,
                                           const double epsilon, ComputeType* mean,
                                           ComputeType* inv_variance) {
  constexpr int block_size = 128;
  constexpr int waves = 32;
  static_assert(block_size % thread_group_width == 0, "");
  constexpr int thread_groups_per_block = block_size / thread_group_width;
  dim3 block_dim(thread_group_width, thread_groups_per_block);
  const int64_t num_blocks =
      (rows / rows_per_access + thread_groups_per_block - 1) / thread_groups_per_block;
  int grid_dim_x;
  {
    GPU(Error_t) err = GetNumBlocks(
        LayerNormWarpImpl<LOAD, STORE, ComputeType, pack_size, max_cols_per_thread,
                          min_cols_per_thread, thread_group_width, rows_per_access, padding>,
        block_size, 0, num_blocks, waves, &grid_dim_x);
    if (err != GPU(Success)) { return err; }
  }
  LayerNormWarpImpl<LOAD, STORE, ComputeType, pack_size, max_cols_per_thread, min_cols_per_thread,
                    thread_group_width, rows_per_access, padding>
      <<<grid_dim_x, block_dim, 0, stream>>>(load, store, rows, cols, epsilon, mean, inv_variance);
  return GPU(PeekAtLastError)();
}

template<typename LOAD, typename STORE, typename ComputeType, int pack_size,
         int max_cols_per_thread, int min_cols_per_thread, int thread_group_width,
         int rows_per_access>
inline GPU(Error_t) DispatchLayerNormWarpImplPadding(GPU(Stream_t) stream, LOAD load, STORE store,
                                                    const int64_t rows, const int64_t cols,
                                                    const double epsilon, ComputeType* mean,
                                                    ComputeType* inv_variance) {
  if (cols == max_cols_per_thread * thread_group_width) {
    // when not padding, min_cols_per_thread must equals to max_cols_per_thread, pass
    // max_cols_per_thread as min_cols_per_thread and max_cols_per_thread param.
    return LaunchLayerNormWarpImpl<LOAD, STORE, ComputeType, pack_size, max_cols_per_thread,
                                   max_cols_per_thread, thread_group_width, rows_per_access, false>(
        stream, load, store, rows, cols, epsilon, mean, inv_variance);
  } else {
    return LaunchLayerNormWarpImpl<LOAD, STORE, ComputeType, pack_size, max_cols_per_thread,
                                   min_cols_per_thread, thread_group_width, rows_per_access, true>(
        stream, load, store, rows, cols, epsilon, mean, inv_variance);
  }
}

template<typename LOAD, typename STORE, typename ComputeType, int pack_size>
typename std::enable_if<pack_size == 1, GPU(Error_t)>::type DispatchLayerNormWarpImplCols(
    GPU(Stream_t) stream, LOAD load, STORE store, const int64_t rows, const int64_t cols,
    const double epsilon, ComputeType* mean, ComputeType* inv_variance) {
  if (cols <= 0) { return GPU(ErrorInvalidValue); }
#define DEFINE_ONE_ELIF(thread_group_width)                                                      \
  else if (cols <= (thread_group_width)*pack_size) {                                             \
    if (rows % 2 == 0) {                                                                         \
      return DispatchLayerNormWarpImplPadding<LOAD, STORE, ComputeType, pack_size, pack_size, 0, \
                                              thread_group_width, 2>(                            \
          stream, load, store, rows, cols, epsilon, mean, inv_variance);                         \
    } else {                                                                                     \
      return DispatchLayerNormWarpImplPadding<LOAD, STORE, ComputeType, pack_size, pack_size, 0, \
                                              thread_group_width, 1>(                            \
          stream, load, store, rows, cols, epsilon, mean, inv_variance);                         \
    }                                                                                            \
  }
  DEFINE_ONE_ELIF(4)
  DEFINE_ONE_ELIF(8)
  DEFINE_ONE_ELIF(16)
  DEFINE_ONE_ELIF(32)
#undef DEFINE_ONE_ELIF
#define DEFINE_ONE_ELIF(max_col, min_col)                                                          \
  else if (cols <= (max_col)*kWarpSize) {                                                          \
    return DispatchLayerNormWarpImplPadding<LOAD, STORE, ComputeType, pack_size, max_col, min_col, \
                                            kWarpSize, 1>(stream, load, store, rows, cols,         \
                                                          epsilon, mean, inv_variance);            \
  }
  DEFINE_ONE_ELIF(2, 1)
  DEFINE_ONE_ELIF(4, 2)
  DEFINE_ONE_ELIF(8, 4)
  DEFINE_ONE_ELIF(12, 8)
  DEFINE_ONE_ELIF(16, 12)
  DEFINE_ONE_ELIF(20, 16)
  DEFINE_ONE_ELIF(24, 20)
  DEFINE_ONE_ELIF(28, 24)
  DEFINE_ONE_ELIF(32, 28)
#undef DEFINE_ONE_ELIF
  else {
    return GPU(ErrorInvalidValue);
  }
}

template<typename LOAD, typename STORE, typename ComputeType, int pack_size>
typename std::enable_if<pack_size == 2, GPU(Error_t)>::type DispatchLayerNormWarpImplCols(
    GPU(Stream_t) stream, LOAD load, STORE store, const int64_t rows, const int64_t cols,
    const double epsilon, ComputeType* mean, ComputeType* inv_variance) {
  if (cols <= 0) { return GPU(ErrorInvalidValue); }
#define DEFINE_ONE_ELIF(thread_group_width)                                                      \
  else if (cols <= (thread_group_width)*pack_size) {                                             \
    if (rows % 2 == 0) {                                                                         \
      return DispatchLayerNormWarpImplPadding<LOAD, STORE, ComputeType, pack_size, pack_size, 0, \
                                              thread_group_width, 2>(                            \
          stream, load, store, rows, cols, epsilon, mean, inv_variance);                         \
    } else {                                                                                     \
      return DispatchLayerNormWarpImplPadding<LOAD, STORE, ComputeType, pack_size, pack_size, 0, \
                                              thread_group_width, 1>(                            \
          stream, load, store, rows, cols, epsilon, mean, inv_variance);                         \
    }                                                                                            \
  }
  DEFINE_ONE_ELIF(4)
  DEFINE_ONE_ELIF(8)
  DEFINE_ONE_ELIF(16)
  DEFINE_ONE_ELIF(32)
#undef DEFINE_ONE_ELIF
#define DEFINE_ONE_ELIF(max_col, min_col)                                                          \
  else if ((cols <= (max_col)*kWarpSize) && (cols > (min_col)*kWarpSize)) {                        \
    return DispatchLayerNormWarpImplPadding<LOAD, STORE, ComputeType, pack_size, max_col, min_col, \
                                            kWarpSize, 1>(stream, load, store, rows, cols,         \
                                                          epsilon, mean, inv_variance);            \
  }
  DEFINE_ONE_ELIF(4, 2)
  DEFINE_ONE_ELIF(8, 4)
  DEFINE_ONE_ELIF(12, 8)
  DEFINE_ONE_ELIF(16, 12)
  DEFINE_ONE_ELIF(20, 16)
  DEFINE_ONE_ELIF(24, 20)
  DEFINE_ONE_ELIF(28, 24)
  DEFINE_ONE_ELIF(32, 28)
#undef DEFINE_ONE_ELIF
  else {
    return GPU(ErrorInvalidValue);
  }
}

template<typename LOAD, typename STORE, typename ComputeType>
struct DispatchLayerNormWarpImplPackSize {
  GPU(Error_t) operator()(GPU(Stream_t) stream, LOAD load, STORE store, const int64_t rows,
                         const int64_t cols, const double epsilon, ComputeType* mean,
                         ComputeType* inv_variance) {
    if (cols % 2 == 0 && CanPackAs<LOAD>(load, 2) && CanPackAs<STORE>(store, 2)) {
      return DispatchLayerNormWarpImplCols<LOAD, STORE, ComputeType, 2>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    } else {
      return DispatchLayerNormWarpImplCols<LOAD, STORE, ComputeType, 1>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    }
  }
};

template<typename LOAD, typename STORE, typename ComputeType>
inline GPU(Error_t) DispatchLayerNormWarpImpl(GPU(Stream_t) stream, LOAD load, STORE store,
                                             const int64_t rows, const int64_t cols,
                                             const double epsilon, ComputeType* mean,
                                             ComputeType* inv_variance) {
  return DispatchLayerNormWarpImplPackSize<LOAD, STORE, ComputeType>()(
      stream, load, store, rows, cols, epsilon, mean, inv_variance);
}

template<typename LOAD, typename STORE, typename ComputeType, int pack_size, int block_size>
__global__ void LayerNormBlockSMemImpl(LOAD load, STORE store, const int64_t rows,
                                       const int64_t cols, const double epsilon, ComputeType* mean,
                                       ComputeType* inv_variance) {
  using LoadType = typename LOAD::LoadType;
  extern __shared__ __align__(sizeof(double)) unsigned char shared_buf[];
  auto* buf = reinterpret_cast<LoadType*>(shared_buf);
  const int tid = threadIdx.x;
  assert(cols % pack_size == 0);
  const int num_packs = static_cast<int>(cols) / pack_size;
  for (int64_t row = blockIdx.x; row < rows; row += gridDim.x) {
    ComputeType thread_mean = 0;
    ComputeType thread_m2 = 0;
    ComputeType thread_count = 0;
    for (int pack_id = tid; pack_id < num_packs; pack_id += block_size) {
      LoadType pack[pack_size];
      load.template load<pack_size>(pack, row, pack_id * pack_size);
#pragma unroll
      for (int i = 0; i < pack_size; ++i) {
        buf[i * num_packs + pack_id] = pack[i];
        WelfordCombine(static_cast<ComputeType>(pack[i]), &thread_mean, &thread_m2, &thread_count);
      }
    }
    ComputeType row_mean = 0;
    ComputeType row_m2 = 0;
    ComputeType row_count = 0;
    WelfordBlockAllReduce<ComputeType>(thread_mean, thread_m2, thread_count, &row_mean, &row_m2,
                                       &row_count);
    ComputeType row_variance = max(Div(row_m2, row_count), static_cast<ComputeType>(0.0));
    ComputeType row_inv_var = Rsqrt(row_variance + static_cast<ComputeType>(epsilon));
    if (threadIdx.x == 0) {
      mean[row] = row_mean;
      inv_variance[row] = row_inv_var;
    }
    for (int pack_id = tid; pack_id < num_packs; pack_id += block_size) {
      ComputeType pack[pack_size];
#pragma unroll
      for (int i = 0; i < pack_size; ++i) {
        pack[i] = (static_cast<ComputeType>(buf[i * num_packs + pack_id]) - row_mean) * row_inv_var;
      }
      store.template store<pack_size>(pack, row, pack_id * pack_size);
    }
  }
}

template<typename LOAD, typename STORE, typename ComputeType, int pack_size, int block_size>
inline GPU(Error_t) LaunchLayerNormBlockSMemImpl(GPU(Stream_t) stream, LOAD load, STORE store,
                                                int smem, const int64_t rows, const int64_t cols,
                                                const double epsilon, ComputeType* mean,
                                                ComputeType* inv_variance) {
  constexpr int waves = 32;
  int grid_dim_x;
  {
    GPU(Error_t) err =
        GetNumBlocks(LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size>,
                     block_size, smem, rows, waves, &grid_dim_x);
    if (err != GPU(Success)) { return err; }
  }
  LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size>
      <<<grid_dim_x, block_size, smem, stream>>>(load, store, rows, cols, epsilon, mean,
                                                 inv_variance);
  return GPU(PeekAtLastError)();
}

template<typename Func>
GPU(Error_t) MaximizeDynamicSharedMemorySize(Func func, const int max_smem_size) {
  GPU(FuncAttributes) attr{};
#ifdef WITH_ROCM
  GPU(Error_t) err = GPU(FuncGetAttributes)(&attr, (const void*)func);
#else
  GPU(Error_t) err = GPU(FuncGetAttributes)(&attr, func);
#endif
  if (err != GPU(Success)) { return err; }
  constexpr int reserved_smem = 1024;  // 1K
#ifdef WITH_ROCM
  return GPU(FuncSetAttribute)((const void*)func, GPU(FuncAttributeMaxDynamicSharedMemorySize),
                              max_smem_size - attr.sharedSizeBytes - reserved_smem);
#else
  return GPU(FuncSetAttribute)(func, GPU(FuncAttributeMaxDynamicSharedMemorySize),
                              max_smem_size - attr.sharedSizeBytes - reserved_smem);
#endif
  
}

template<typename LOAD, typename STORE, typename ComputeType, int pack_size>
inline GPU(Error_t) TryDispatchLayerNormBlockSMemImplBlockSize(
    GPU(Stream_t) stream, LOAD load, STORE store, const int64_t rows, const int64_t cols,
    const double epsilon, ComputeType* mean, ComputeType* inv_variance, bool* success) {
  constexpr int block_size_conf_1 = 128;
  constexpr int block_size_conf_2 = 256;
  constexpr int block_size_conf_3 = 512;
  constexpr int block_size_conf_4 = 1024;

  int dev = 0;
  {
    GPU(Error_t) err = GPU(GetDevice)(&dev);
    if (err != GPU(Success)) { return err; }
  }

  int sm_count = 0;
  {
    GPU(Error_t) err = GPU(DeviceGetAttribute)(&sm_count, GPUMultiProcessorCount, dev);
    if (err != GPU(Success)) { return err; }
  }

  static const bool max_smem_configed = [=]() {
    int max_smem_size = 0;
    GPU(Error_t) err =
        GPU(DeviceGetAttribute)(&max_smem_size, GPUMaxSharedMemoryPerBlockOptin, dev);
    if (err != GPU(Success)) { return false; }

    err = MaximizeDynamicSharedMemorySize(
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size_conf_1>,
        max_smem_size);
    if (err != GPU(Success)) { return false; }
    err = MaximizeDynamicSharedMemorySize(
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size_conf_2>,
        max_smem_size);
    if (err != GPU(Success)) { return false; }
    err = MaximizeDynamicSharedMemorySize(
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size_conf_3>,
        max_smem_size);
    if (err != GPU(Success)) { return false; }
    err = MaximizeDynamicSharedMemorySize(
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size_conf_4>,
        max_smem_size);
    if (err != GPU(Success)) { return false; }

    return true;
  }();

  const size_t smem = cols * sizeof(typename LOAD::LoadType);

  int max_active_blocks_conf_1;
  {
    GPU(Error_t) err = GPU(OccupancyMaxActiveBlocksPerMultiprocessor)(
        &max_active_blocks_conf_1,
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size_conf_1>,
        block_size_conf_1, smem);
    if (err != GPU(Success)) { return err; }
  }
  if (max_active_blocks_conf_1 <= 0) {
    *success = false;
    return GPU(Success);
  }

  int max_active_blocks_conf_4;
  {
    GPU(Error_t) err = GPU(OccupancyMaxActiveBlocksPerMultiprocessor)(
        &max_active_blocks_conf_4,
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size_conf_4>,
        block_size_conf_4, smem);
    if (err != GPU(Success)) { return err; }
  }

  if (max_active_blocks_conf_4 == max_active_blocks_conf_1
      || (max_active_blocks_conf_4 > 0 && rows <= sm_count)) {
    *success = true;
    return LaunchLayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size_conf_4>(
        stream, load, store, smem, rows, cols, epsilon, mean, inv_variance);
  }

  int max_active_blocks_conf_3;
  {
    GPU(Error_t) err = GPU(OccupancyMaxActiveBlocksPerMultiprocessor)(
        &max_active_blocks_conf_3,
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size_conf_3>,
        block_size_conf_3, smem);
    if (err != GPU(Success)) { return err; }
  }
  if (max_active_blocks_conf_3 == max_active_blocks_conf_1
      || (max_active_blocks_conf_3 > 0 && rows <= sm_count)) {
    *success = true;
    return LaunchLayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size_conf_3>(
        stream, load, store, smem, rows, cols, epsilon, mean, inv_variance);
  }

  int max_active_blocks_conf_2;
  {
    GPU(Error_t) err = GPU(OccupancyMaxActiveBlocksPerMultiprocessor)(
        &max_active_blocks_conf_2,
        LayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size_conf_2>,
        block_size_conf_2, smem);
    if (err != GPU(Success)) { return err; }
  }
  if (max_active_blocks_conf_2 == max_active_blocks_conf_1
      || (max_active_blocks_conf_2 > 0 && rows <= sm_count)) {
    *success = true;
    return LaunchLayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size_conf_2>(
        stream, load, store, smem, rows, cols, epsilon, mean, inv_variance);
  }

  *success = true;
  return LaunchLayerNormBlockSMemImpl<LOAD, STORE, ComputeType, pack_size, block_size_conf_1>(
      stream, load, store, smem, rows, cols, epsilon, mean, inv_variance);
}

template<typename LOAD, typename STORE, typename ComputeType>
struct TryDispatchLayerNormBlockSMemImplPackSize {
  GPU(Error_t) operator()(GPU(Stream_t) stream, LOAD load, STORE store, const int64_t rows,
                         const int64_t cols, const double epsilon, ComputeType* mean,
                         ComputeType* inv_variance, bool* success) {
    if (cols % 4 == 0 && CanPackAs<LOAD>(load, 4) && CanPackAs<STORE>(store, 4)) {
      return TryDispatchLayerNormBlockSMemImplBlockSize<LOAD, STORE, ComputeType, 4>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance, success);
    } else if (cols % 2 == 0 && CanPackAs<LOAD>(load, 2) && CanPackAs<STORE>(store, 2)) {
      return TryDispatchLayerNormBlockSMemImplBlockSize<LOAD, STORE, ComputeType, 2>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance, success);
    } else {
      return TryDispatchLayerNormBlockSMemImplBlockSize<LOAD, STORE, ComputeType, 1>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance, success);
    }
  }
};

template<typename LOAD, typename STORE, typename ComputeType>
inline GPU(Error_t) TryDispatchLayerNormBlockSMemImpl(GPU(Stream_t) stream, LOAD load, STORE store,
                                                     const int64_t rows, const int64_t cols,
                                                     const double epsilon, ComputeType* mean,
                                                     ComputeType* inv_variance, bool* success) {
  return TryDispatchLayerNormBlockSMemImplPackSize<LOAD, STORE, ComputeType>()(
      stream, load, store, rows, cols, epsilon, mean, inv_variance, success);
}

template<typename LOAD, typename STORE, typename ComputeType, int pack_size, int block_size>
__global__ void __launch_bounds__(1024)
    LayerNormBlockUncachedImpl(LOAD load, STORE store, const int64_t rows, const int64_t cols,
                               const double epsilon, ComputeType* mean, ComputeType* inv_variance) {
  using LoadType = typename LOAD::LoadType;
  const int tid = threadIdx.x;
  assert(cols % pack_size == 0);
  const int num_packs = static_cast<int>(cols) / pack_size;
  for (int64_t row = blockIdx.x; row < rows; row += gridDim.x) {
    ComputeType thread_mean = 0;
    ComputeType thread_m2 = 0;
    ComputeType thread_count = 0;
    for (int pack_id = tid; pack_id < num_packs; pack_id += block_size) {
      LoadType pack[pack_size];
      load.template load<pack_size>(pack, row, pack_id * pack_size);
#pragma unroll
      for (int i = 0; i < pack_size; ++i) {
        WelfordCombine(static_cast<ComputeType>(pack[i]), &thread_mean, &thread_m2, &thread_count);
      }
    }
    ComputeType row_mean = 0;
    ComputeType row_m2 = 0;
    ComputeType row_count = 0;
    WelfordBlockAllReduce<ComputeType>(thread_mean, thread_m2, thread_count, &row_mean, &row_m2,
                                       &row_count);
    ComputeType row_variance = max(Div(row_m2, row_count), static_cast<ComputeType>(0.0));
    ComputeType row_inv_var = Rsqrt(row_variance + static_cast<ComputeType>(epsilon));
    if (threadIdx.x == 0) {
      mean[row] = row_mean;
      inv_variance[row] = row_inv_var;
    }
    for (int pack_id = tid; pack_id < num_packs; pack_id += block_size) {
      LoadType pack[pack_size];
      ComputeType dst_pack[pack_size];
      const int pack_offset = pack_id * pack_size;
      load.template load<pack_size>(pack, row, pack_offset);
#pragma unroll
      for (int i = 0; i < pack_size; ++i) {
        dst_pack[i] = (static_cast<ComputeType>(pack[i]) - row_mean) * row_inv_var;
      }
      store.template store<pack_size>(dst_pack, row, pack_offset);
    }
  }
}

template<typename LOAD, typename STORE, typename ComputeType, int pack_size>
inline GPU(Error_t) LaunchLayerNormBlockUncachedImpl(GPU(Stream_t) stream, LOAD load, STORE store,
                                                    const int64_t rows, const int64_t cols,
                                                    const double epsilon, ComputeType* mean,
                                                    ComputeType* inv_variance) {
  constexpr int block_size = 1024;
  constexpr int waves = 32;
  int grid_dim_x;
  {
    GPU(Error_t) err =
        GetNumBlocks(LayerNormBlockUncachedImpl<LOAD, STORE, ComputeType, pack_size, block_size>,
                     block_size, 0, rows, waves, &grid_dim_x);
    if (err != GPU(Success)) { return err; }
  }
  LayerNormBlockUncachedImpl<LOAD, STORE, ComputeType, pack_size, block_size>
      <<<grid_dim_x, block_size, 0, stream>>>(load, store, rows, cols, epsilon, mean, inv_variance);
  return GPU(PeekAtLastError)();
}

template<typename LOAD, typename STORE, typename ComputeType>
struct DispatchLayerNormBlockUncachedImplPackSize {
  GPU(Error_t) operator()(GPU(Stream_t) stream, LOAD load, STORE store, const int64_t rows,
                         const int64_t cols, const double epsilon, ComputeType* mean,
                         ComputeType* inv_variance) {
    if (cols % 4 == 0 && CanPackAs<LOAD>(load, 4) && CanPackAs<STORE>(store, 4)) {
      return LaunchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType, 4>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    } else if (cols % 2 == 0 && CanPackAs<LOAD>(load, 2) && CanPackAs<STORE>(store, 2)) {
      return LaunchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType, 2>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    } else {
      return LaunchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType, 1>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    }
  }
};

template<typename LOAD, typename STORE, typename ComputeType>
inline GPU(Error_t) DispatchLayerNormBlockUncachedImpl(GPU(Stream_t) stream, LOAD load, STORE store,
                                                      const int64_t rows, const int64_t cols,
                                                      const double epsilon, ComputeType* mean,
                                                      ComputeType* inv_variance) {
  return DispatchLayerNormBlockUncachedImplPackSize<LOAD, STORE, ComputeType>()(
      stream, load, store, rows, cols, epsilon, mean, inv_variance);
}

template<typename LOAD, typename STORE, typename ComputeType>
inline typename std::enable_if<!std::is_same<ComputeType, double>::value, GPU(Error_t)>::type
DispatchLayerNorm(GPU(Stream_t) stream, LOAD load, STORE store, const int64_t rows,
                  const int64_t cols, const double epsilon, ComputeType* mean,
                  ComputeType* inv_variance) {
  if (cols <= 1024) {
    return DispatchLayerNormWarpImpl<LOAD, STORE, ComputeType>(stream, load, store, rows, cols,
                                                               epsilon, mean, inv_variance);
  } else {
    bool dispatch_smem_impl_success;
    {
      GPU(Error_t) err = TryDispatchLayerNormBlockSMemImpl<LOAD, STORE, ComputeType>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance,
          &dispatch_smem_impl_success);
      if (err != GPU(Success)) { return err; }
    }
    if (!dispatch_smem_impl_success) {
      return DispatchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType>(
          stream, load, store, rows, cols, epsilon, mean, inv_variance);
    }
    return GPU(Success);
  }
}

template<typename LOAD, typename STORE, typename ComputeType>
inline typename std::enable_if<std::is_same<ComputeType, double>::value, GPU(Error_t)>::type
DispatchLayerNorm(GPU(Stream_t) stream, LOAD load, STORE store, const int64_t rows,
                  const int64_t cols, const double epsilon, ComputeType* mean,
                  ComputeType* inv_variance) {
  return DispatchLayerNormBlockUncachedImpl<LOAD, STORE, ComputeType>(
      stream, load, store, rows, cols, epsilon, mean, inv_variance);
}

/*
LayerNormGrad dx:
normalized = (x - mean) * inv_var
sum_stats1 = sum(scaled_dy)
sum_stats2 = sum(scaled_dy * normalized)
dx = cols * dy - sum_stats1 - normalized * sum_stats2
dx *= inv_var / cols
*/
template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType,
         int pack_size, int max_cols_per_thread, int min_cols_per_thread, int thread_group_width,
         int rows_per_access>
__global__ void LayerNormGradWarpImpl(LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy, STORE store,
                                      const ComputeType* mean, const ComputeType* inv_variance,
                                      const int64_t rows, const int64_t cols) {
  using LoadTypeX = typename LOAD_X::LoadType;
  using LoadTypeDy = typename LOAD_SCALED_DY::LoadType;
  static_assert(max_cols_per_thread % pack_size == 0, "");
  static_assert(min_cols_per_thread % pack_size == 0, "");
  constexpr int max_num_packs = max_cols_per_thread / pack_size;
  constexpr int min_num_packs = min_cols_per_thread / pack_size;
  assert(cols <= max_cols_per_thread * thread_group_width);
  static_assert(thread_group_width <= kWarpSize, "");
  static_assert(kWarpSize % thread_group_width == 0, "");
  ComputeType normalized_buf[rows_per_access][max_cols_per_thread];
  ComputeType dy_buf[rows_per_access][max_cols_per_thread];
  const ComputeType one_over_cols = static_cast<ComputeType>(1.0) / static_cast<ComputeType>(cols);
  const int64_t global_thread_group_id = blockIdx.x * blockDim.y + threadIdx.y;
  const int64_t num_global_thread_group = gridDim.x * blockDim.y;
  const int lane_id = threadIdx.x;
  const int64_t step = num_global_thread_group * rows_per_access;
  for (int64_t row = global_thread_group_id * rows_per_access; row < rows; row += step) {
    ComputeType sum_stats1[rows_per_access];
    ComputeType sum_stats2[rows_per_access];
    ComputeType inv_variance_buf[rows_per_access];
#pragma unroll
    for (int row_id = 0; row_id < rows_per_access; ++row_id) {
      const int global_row_id = row + row_id;
      ComputeType mean_val = mean[global_row_id];
      inv_variance_buf[row_id] = inv_variance[global_row_id];
      sum_stats1[row_id] = 0;
      sum_stats2[row_id] = 0;
      ComputeType* row_normalized_buf = normalized_buf[row_id];
      ComputeType* row_dy_buf = dy_buf[row_id];
#pragma unroll
      for (int pack_id = 0; pack_id < min_num_packs; ++pack_id) {
        const int col = (pack_id * thread_group_width + lane_id) * pack_size;
        const int pack_offset = pack_id * pack_size;
        LoadTypeX pack_x[pack_size];
        LoadTypeDy pack_dy[pack_size];
        load_x.template load<pack_size>(pack_x, global_row_id, col);
        load_scaled_dy.template load<pack_size>(pack_dy, global_row_id, col);
#pragma unroll
        for (int i = 0; i < pack_size; ++i) {
          const int col_id = pack_offset + i;
          // row_normalized_buf store x
          row_normalized_buf[col_id] =
              (static_cast<ComputeType>(pack_x[i]) - mean_val) * inv_variance_buf[row_id];
          row_dy_buf[col_id] = static_cast<ComputeType>(pack_dy[i]);
          sum_stats1[row_id] += row_dy_buf[col_id];
          sum_stats2[row_id] += row_dy_buf[col_id] * row_normalized_buf[col_id];
        }
      }
#pragma unroll
      for (int pack_id = min_num_packs; pack_id < max_num_packs; ++pack_id) {
        const int col = (pack_id * thread_group_width + lane_id) * pack_size;
        const int pack_offset = pack_id * pack_size;
        if (col < cols) {
          LoadTypeX pack_x[pack_size];
          LoadTypeDy pack_dy[pack_size];
          load_x.template load<pack_size>(pack_x, global_row_id, col);
          load_scaled_dy.template load<pack_size>(pack_dy, global_row_id, col);
#pragma unroll
          for (int i = 0; i < pack_size; ++i) {
            const int col_id = pack_offset + i;
            // row_normalized_buf store x
            row_normalized_buf[col_id] =
                (static_cast<ComputeType>(pack_x[i]) - mean_val) * inv_variance_buf[row_id];
            row_dy_buf[col_id] = static_cast<ComputeType>(pack_dy[i]);
            sum_stats1[row_id] += row_dy_buf[col_id];
            sum_stats2[row_id] += row_dy_buf[col_id] * row_normalized_buf[col_id];
          }
        }
      }
    }
    ComputeType warp_sum_stats1[rows_per_access];
    ComputeType warp_sum_stats2[rows_per_access];
#pragma unroll
    for (int row_id = 0; row_id < rows_per_access; ++row_id) {
      warp_sum_stats1[row_id] =
          WarpAllReduce<SumOp, ComputeType, thread_group_width>(sum_stats1[row_id]);
      warp_sum_stats2[row_id] =
          WarpAllReduce<SumOp, ComputeType, thread_group_width>(sum_stats2[row_id]);
    }
#pragma unroll
    for (int row_id = 0; row_id < rows_per_access; ++row_id) {
      const int global_row_id = row + row_id;
      ComputeType* row_normalized_buf = normalized_buf[row_id];
      ComputeType* row_dy_buf = dy_buf[row_id];
      const ComputeType inv_variance_over_cols = inv_variance_buf[row_id] * one_over_cols;
#pragma unroll
      for (int pack_id = 0; pack_id < min_num_packs; ++pack_id) {
        const int col = (pack_id * thread_group_width + lane_id) * pack_size;
        const int pack_offset = pack_id * pack_size;
        for (int i = 0; i < pack_size; ++i) {
          const int col_id = pack_offset + i;
          row_dy_buf[col_id] = (cols * row_dy_buf[col_id] - warp_sum_stats1[row_id]
                                - row_normalized_buf[col_id] * warp_sum_stats2[row_id])
                               * inv_variance_over_cols;
        }
        store.template store<pack_size>(row_dy_buf + pack_offset, global_row_id, col);
      }
#pragma unroll
      for (int pack_id = min_num_packs; pack_id < max_num_packs; ++pack_id) {
        const int col = (pack_id * thread_group_width + lane_id) * pack_size;
        if (col < cols) {
          const int pack_offset = pack_id * pack_size;
          for (int i = 0; i < pack_size; ++i) {
            const int col_id = pack_offset + i;
            row_dy_buf[col_id] = (cols * row_dy_buf[col_id] - warp_sum_stats1[row_id]
                                  - row_normalized_buf[col_id] * warp_sum_stats2[row_id])
                                 * inv_variance_over_cols;
          }
          store.template store<pack_size>(row_dy_buf + pack_offset, global_row_id, col);
        }
      }
    }
  }
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType,
         int pack_size, int max_cols_per_thread, int min_cols_per_thread, int thread_group_width,
         int rows_per_access>
inline GPU(Error_t) LaunchLayerNormGradWarpImpl(GPU(Stream_t) stream, LOAD_X load_x,
                                               LOAD_SCALED_DY load_scaled_dy, STORE store,
                                               const ComputeType* mean,
                                               const ComputeType* inv_variance, const int64_t rows,
                                               const int64_t cols) {
  constexpr int block_size = 128;
  constexpr int waves = 32;
  static_assert(block_size % thread_group_width == 0, "");
  constexpr int thread_groups_per_block = block_size / thread_group_width;
  dim3 block_dim(thread_group_width, thread_groups_per_block);
  const int64_t num_blocks =
      (rows / rows_per_access + thread_groups_per_block - 1) / thread_groups_per_block;
  int grid_dim_x;
  {
    GPU(Error_t) err =
        GetNumBlocks(LayerNormGradWarpImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                           max_cols_per_thread, min_cols_per_thread,
                                           thread_group_width, rows_per_access>,
                     block_size, 0, num_blocks, waves, &grid_dim_x);
    if (err != GPU(Success)) { return err; }
  }
  LayerNormGradWarpImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size, max_cols_per_thread,
                        min_cols_per_thread, thread_group_width, rows_per_access>
      <<<grid_dim_x, block_dim, 0, stream>>>(load_x, load_scaled_dy, store, mean, inv_variance,
                                             rows, cols);
  return GPU(PeekAtLastError)();
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType,
         int pack_size, int max_cols_per_thread, int min_cols_per_thread, int thread_group_width,
         int rows_per_access>
inline GPU(Error_t) DispatchLayerNormGradWarpImplPadding(GPU(Stream_t) stream, LOAD_X load_x,
                                                        LOAD_SCALED_DY load_scaled_dy, STORE store,
                                                        const ComputeType* mean,
                                                        const ComputeType* inv_variance,
                                                        const int64_t rows, const int64_t cols) {
  if (cols == max_cols_per_thread * thread_group_width) {
    // when not padding, min_cols_per_thread must equals to max_cols_per_thread, pass
    // max_cols_per_thread as min_cols_per_thread and max_cols_per_thread param.
    return LaunchLayerNormGradWarpImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                       max_cols_per_thread, max_cols_per_thread, thread_group_width,
                                       rows_per_access>(stream, load_x, load_scaled_dy, store, mean,
                                                        inv_variance, rows, cols);
  } else {
    return LaunchLayerNormGradWarpImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                       max_cols_per_thread, min_cols_per_thread, thread_group_width,
                                       rows_per_access>(stream, load_x, load_scaled_dy, store, mean,
                                                        inv_variance, rows, cols);
  }
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType,
         int pack_size>
typename std::enable_if<pack_size == 1, GPU(Error_t)>::type DispatchLayerNormGradWarpImplCols(
    GPU(Stream_t) stream, LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy, STORE store,
    const ComputeType* mean, const ComputeType* inv_variance, const int64_t rows,
    const int64_t cols) {
  if (cols <= 0) { return GPU(ErrorInvalidValue); }
#define DEFINE_ONE_ELIF(thread_group_width)                                                        \
  else if (cols <= (thread_group_width)*pack_size) {                                               \
    if (rows % 2 == 0) {                                                                           \
      return DispatchLayerNormGradWarpImplPadding<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType,      \
                                                  pack_size, pack_size, 0, thread_group_width, 2>( \
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);                  \
    } else {                                                                                       \
      return DispatchLayerNormGradWarpImplPadding<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType,      \
                                                  pack_size, pack_size, 0, thread_group_width, 1>( \
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);                  \
    }                                                                                              \
  }
  DEFINE_ONE_ELIF(4)
  DEFINE_ONE_ELIF(8)
  DEFINE_ONE_ELIF(16)
  DEFINE_ONE_ELIF(32)
#undef DEFINE_ONE_ELIF
#define DEFINE_ONE_ELIF(max_col, min_col)                                                   \
  else if (cols <= (max_col)*kWarpSize) {                                                   \
    return DispatchLayerNormGradWarpImplPadding<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, \
                                                pack_size, max_col, min_col, kWarpSize, 1>( \
        stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);             \
  }
  DEFINE_ONE_ELIF(2, 1)
  DEFINE_ONE_ELIF(4, 2)
  DEFINE_ONE_ELIF(8, 4)
  DEFINE_ONE_ELIF(12, 8)
  DEFINE_ONE_ELIF(16, 12)
  DEFINE_ONE_ELIF(20, 16)
  DEFINE_ONE_ELIF(24, 20)
  DEFINE_ONE_ELIF(28, 24)
  DEFINE_ONE_ELIF(32, 28)
#undef DEFINE_ONE_ELIF
  else {
    return GPU(ErrorInvalidValue);
  }
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
struct DispatchLayerNormGradWarpImplPackSize {
  GPU(Error_t) operator()(GPU(Stream_t) stream, LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy,
                         STORE store, const ComputeType* mean, const ComputeType* inv_variance,
                         const int64_t rows, const int64_t cols) {
    return DispatchLayerNormGradWarpImplCols<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, 1>(
        stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
  }
};

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
inline GPU(Error_t) DispatchLayerNormGradWarpImpl(GPU(Stream_t) stream, LOAD_X load_x,
                                                 LOAD_SCALED_DY load_scaled_dy, STORE store,
                                                 const ComputeType* mean,
                                                 const ComputeType* inv_variance,
                                                 const int64_t rows, const int64_t cols) {
  return DispatchLayerNormGradWarpImplPackSize<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType>()(
      stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType,
         int pack_size, int block_size>
__global__ void LayerNormGradBlockSMemImpl(LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy,
                                           STORE store, const ComputeType* mean,
                                           const ComputeType* inv_variance, const int64_t rows,
                                           const int64_t cols) {
  using LoadTypeX = typename LOAD_X::LoadType;
  using LoadTypeDy = typename LOAD_SCALED_DY::LoadType;
  extern __shared__ __align__(sizeof(double)) unsigned char grad_shared_buf[];
  auto* normalized_buf = reinterpret_cast<LoadTypeX*>(grad_shared_buf);
  auto* dy_buf = reinterpret_cast<LoadTypeDy*>(normalized_buf + cols);
  const int tid = threadIdx.x;
  assert(cols % pack_size == 0);
  const int num_packs = static_cast<int>(cols) / pack_size;
  const ComputeType one_over_cols = static_cast<ComputeType>(1.0) / static_cast<ComputeType>(cols);
  for (int64_t row = blockIdx.x; row < rows; row += gridDim.x) {
    ComputeType sum_stats1 = 0;
    ComputeType sum_stats2 = 0;
    const ComputeType mean_val = mean[row];
    const ComputeType inv_variance_val = inv_variance[row];
    const ComputeType inv_variance_over_cols = inv_variance_val * one_over_cols;
    for (int pack_id = tid; pack_id < num_packs; pack_id += block_size) {
      LoadTypeX x_pack[pack_size];
      LoadTypeDy dy_pack[pack_size];
      load_x.template load<pack_size>(x_pack, row, pack_id * pack_size);
      load_scaled_dy.template load<pack_size>(dy_pack, row, pack_id * pack_size);
#pragma unroll
      for (int i = 0; i < pack_size; ++i) {
        const int buf_offset = i * num_packs + pack_id;
        ComputeType normalized =
            (static_cast<ComputeType>(x_pack[i]) - mean_val) * inv_variance_val;
        normalized_buf[buf_offset] = static_cast<LoadTypeX>(normalized);
        dy_buf[buf_offset] = dy_pack[i];
        sum_stats1 += static_cast<ComputeType>(dy_pack[i]);
        sum_stats2 += static_cast<ComputeType>(dy_pack[i]) * normalized;
      }
    }
    const ComputeType row_sum_stats1 = BlockAllReduce<SumOp, ComputeType, block_size>(sum_stats1);
    const ComputeType row_sum_stats2 = BlockAllReduce<SumOp, ComputeType, block_size>(sum_stats2);
    for (int pack_id = tid; pack_id < num_packs; pack_id += block_size) {
      ComputeType pack[pack_size];
#pragma unroll
      for (int i = 0; i < pack_size; ++i) {
        const int buf_offset = i * num_packs + pack_id;
        pack[i] = (cols * static_cast<ComputeType>(dy_buf[buf_offset]) - row_sum_stats1
                   - static_cast<ComputeType>(normalized_buf[buf_offset]) * row_sum_stats2)
                  * inv_variance_over_cols;
      }
      store.template store<pack_size>(pack, row, pack_id * pack_size);
    }
  }
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType,
         int pack_size, int block_size>
inline GPU(Error_t) LaunchLayerNormGradBlockSMemImpl(GPU(Stream_t) stream, LOAD_X load_x,
                                                    LOAD_SCALED_DY load_scaled_dy, STORE store,
                                                    const ComputeType* mean,
                                                    const ComputeType* inv_variance, int smem,
                                                    const int64_t rows, const int64_t cols) {
  constexpr int waves = 32;
  int grid_dim_x;
  {
    GPU(Error_t) err = GetNumBlocks(LayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE,
                                                              ComputeType, pack_size, block_size>,
                                   block_size, smem, rows, waves, &grid_dim_x);
    if (err != GPU(Success)) { return err; }
  }
  LayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size, block_size>
      <<<grid_dim_x, block_size, smem, stream>>>(load_x, load_scaled_dy, store, mean, inv_variance,
                                                 rows, cols);
  return GPU(PeekAtLastError)();
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType,
         int pack_size>
inline GPU(Error_t) TryDispatchLayerNormGradBlockSMemImplBlockSize(
    GPU(Stream_t) stream, LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy, STORE store,
    const ComputeType* mean, const ComputeType* inv_variance, const int64_t rows,
    const int64_t cols, bool* success) {
  constexpr int block_size_conf_1 = 128;
  constexpr int block_size_conf_2 = 256;
  constexpr int block_size_conf_3 = 512;
  constexpr int block_size_conf_4 = 1024;

  int dev = 0;
  {
    GPU(Error_t) err = GPU(GetDevice)(&dev);
    if (err != GPU(Success)) { return err; }
  }

  int sm_count = 0;
  {
    GPU(Error_t) err = GPU(DeviceGetAttribute)(&sm_count, GPUMultiProcessorCount, dev);
    if (err != GPU(Success)) { return err; }
  }

  static const bool max_smem_configed = [=]() {
    int max_smem_size = 0;
    GPU(Error_t) err =
        GPU(DeviceGetAttribute)(&max_smem_size, GPUMaxSharedMemoryPerBlockOptin, dev);
    if (err != GPU(Success)) { return false; }

    err = MaximizeDynamicSharedMemorySize(
        LayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                   block_size_conf_1>,
        max_smem_size);
    if (err != GPU(Success)) { return false; }
    err = MaximizeDynamicSharedMemorySize(
        LayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                   block_size_conf_2>,
        max_smem_size);
    if (err != GPU(Success)) { return false; }
    err = MaximizeDynamicSharedMemorySize(
        LayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                   block_size_conf_3>,
        max_smem_size);
    if (err != GPU(Success)) { return false; }
    err = MaximizeDynamicSharedMemorySize(
        LayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                   block_size_conf_4>,
        max_smem_size);
    if (err != GPU(Success)) { return false; }

    return true;
  }();

  using LoadTypeX = typename LOAD_X::LoadType;
  using LoadTypeDy = typename LOAD_SCALED_DY::LoadType;
  const size_t smem = cols * (sizeof(LoadTypeX) + sizeof(LoadTypeDy));

  int max_active_blocks_conf_1;
  {
    GPU(Error_t) err = GPU(OccupancyMaxActiveBlocksPerMultiprocessor)(
        &max_active_blocks_conf_1,
        LayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                   block_size_conf_1>,
        block_size_conf_1, smem);
    if (err != GPU(Success)) { return err; }
  }
  if (max_active_blocks_conf_1 <= 0) {
    *success = false;
    return GPU(Success);
  }

  int max_active_blocks_conf_4;
  {
    GPU(Error_t) err = GPU(OccupancyMaxActiveBlocksPerMultiprocessor)(
        &max_active_blocks_conf_4,
        LayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                   block_size_conf_4>,
        block_size_conf_4, smem);
    if (err != GPU(Success)) { return err; }
  }
  if (max_active_blocks_conf_4 == max_active_blocks_conf_1
      || (max_active_blocks_conf_4 > 0 && rows <= sm_count)) {
    *success = true;
    return LaunchLayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                            block_size_conf_4>(
        stream, load_x, load_scaled_dy, store, mean, inv_variance, smem, rows, cols);
  }

  int max_active_blocks_conf_3;
  {
    GPU(Error_t) err = GPU(OccupancyMaxActiveBlocksPerMultiprocessor)(
        &max_active_blocks_conf_3,
        LayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                   block_size_conf_3>,
        block_size_conf_3, smem);
    if (err != GPU(Success)) { return err; }
  }
  if (max_active_blocks_conf_3 == max_active_blocks_conf_1
      || (max_active_blocks_conf_3 > 0 && rows <= sm_count)) {
    *success = true;
    return LaunchLayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                            block_size_conf_3>(
        stream, load_x, load_scaled_dy, store, mean, inv_variance, smem, rows, cols);
  }

  int max_active_blocks_conf_2;
  {
    GPU(Error_t) err = GPU(OccupancyMaxActiveBlocksPerMultiprocessor)(
        &max_active_blocks_conf_2,
        LayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                   block_size_conf_2>,
        block_size_conf_2, smem);
    if (err != GPU(Success)) { return err; }
  }
  if (max_active_blocks_conf_2 == max_active_blocks_conf_1
      || (max_active_blocks_conf_2 > 0 && rows <= sm_count)) {
    *success = true;
    return LaunchLayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                            block_size_conf_2>(
        stream, load_x, load_scaled_dy, store, mean, inv_variance, smem, rows, cols);
  }

  *success = true;
  return LaunchLayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                          block_size_conf_1>(stream, load_x, load_scaled_dy, store,
                                                             mean, inv_variance, smem, rows, cols);
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
struct TryDispatchLayerNormGradBlockSMemImplPackSize {
  GPU(Error_t) operator()(GPU(Stream_t) stream, LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy,
                         STORE store, const ComputeType* mean, const ComputeType* inv_variance,
                         const int64_t rows, const int64_t cols, bool* success) {
    if (cols % 2 == 0 && CanPackAs<LOAD_X>(load_x, 2)
        && CanPackAs<LOAD_SCALED_DY>(load_scaled_dy, 2) && CanPackAs<STORE>(store, 2)) {
      return TryDispatchLayerNormGradBlockSMemImplBlockSize<LOAD_X, LOAD_SCALED_DY, STORE,
                                                            ComputeType, 2>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols, success);
    } else {
      return TryDispatchLayerNormGradBlockSMemImplBlockSize<LOAD_X, LOAD_SCALED_DY, STORE,
                                                            ComputeType, 1>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols, success);
    }
  }
};

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
inline GPU(Error_t) TryDispatchLayerNormGradBlockSMemImpl(GPU(Stream_t) stream, LOAD_X load_x,
                                                         LOAD_SCALED_DY load_scaled_dy, STORE store,
                                                         const ComputeType* mean,
                                                         const ComputeType* inv_variance,
                                                         const int64_t rows, const int64_t cols,
                                                         bool* success) {
  return TryDispatchLayerNormGradBlockSMemImplPackSize<LOAD_X, LOAD_SCALED_DY, STORE,
                                                       ComputeType>()(
      stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols, success);
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType,
         int pack_size, int block_size>
__global__ void LayerNormGradBlockUncachedImpl(LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy,
                                               STORE store, const ComputeType* mean,
                                               const ComputeType* inv_variance, const int64_t rows,
                                               const int64_t cols) {
  using LoadTypeX = typename LOAD_X::LoadType;
  using LoadTypeDy = typename LOAD_SCALED_DY::LoadType;
  const int tid = threadIdx.x;
  assert(cols % pack_size == 0);
  const int num_packs = static_cast<int>(cols) / pack_size;
  const ComputeType one_over_cols = static_cast<ComputeType>(1.0) / static_cast<ComputeType>(cols);
  for (int64_t row = blockIdx.x; row < rows; row += gridDim.x) {
    const ComputeType mean_val = mean[row];
    const ComputeType inv_variance_val = inv_variance[row];
    const ComputeType inv_variance_over_cols = inv_variance_val * one_over_cols;
    ComputeType sum_stats1 = 0;
    ComputeType sum_stats2 = 0;
    for (int pack_id = tid; pack_id < num_packs; pack_id += block_size) {
      const int pack_offset = pack_id * pack_size;
      LoadTypeX x_pack[pack_size];
      LoadTypeDy dy_pack[pack_size];
      load_x.template load<pack_size>(x_pack, row, pack_offset);
      load_scaled_dy.template load<pack_size>(dy_pack, row, pack_offset);
#pragma unroll
      for (int i = 0; i < pack_size; ++i) {
        sum_stats1 += static_cast<ComputeType>(dy_pack[i]);
        sum_stats2 += static_cast<ComputeType>(dy_pack[i])
                      * (static_cast<ComputeType>(x_pack[i]) - mean_val) * inv_variance_val;
      }
    }
    const ComputeType row_sum_stats1 = BlockAllReduce<SumOp, ComputeType, block_size>(sum_stats1);
    const ComputeType row_sum_stats2 = BlockAllReduce<SumOp, ComputeType, block_size>(sum_stats2);
    for (int pack_id = tid; pack_id < num_packs; pack_id += block_size) {
      const int pack_offset = pack_id * pack_size;
      LoadTypeX x_pack[pack_size];
      LoadTypeDy dy_pack[pack_size];
      ComputeType dx_pack[pack_size];
      load_x.template load<pack_size>(x_pack, row, pack_offset);
      load_scaled_dy.template load<pack_size>(dy_pack, row, pack_offset);
#pragma unroll
      for (int i = 0; i < pack_size; ++i) {
        dx_pack[i] =
            (cols * static_cast<ComputeType>(dy_pack[i]) - row_sum_stats1
             - (static_cast<ComputeType>(x_pack[i]) - mean_val) * inv_variance_val * row_sum_stats2)
            * inv_variance_over_cols;
      }
      store.template store<pack_size>(dx_pack, row, pack_offset);
    }
  }
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType,
         int pack_size, int block_size>
inline GPU(Error_t) LaunchLayerNormGradBlockUncachedImpl(GPU(Stream_t) stream, LOAD_X load_x,
                                                        LOAD_SCALED_DY load_scaled_dy, STORE store,
                                                        const ComputeType* mean,
                                                        const ComputeType* inv_variance,
                                                        const int64_t rows, const int64_t cols) {
  constexpr int waves = 32;
  int grid_dim_x;
  {
    GPU(Error_t) err =
        GetNumBlocks(LayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType,
                                                    pack_size, block_size>,
                     block_size, 0, rows, waves, &grid_dim_x);
    if (err != GPU(Success)) { return err; }
  }
  LayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size, block_size>
      <<<grid_dim_x, block_size, 0, stream>>>(load_x, load_scaled_dy, store, mean, inv_variance,
                                              rows, cols);
  return GPU(PeekAtLastError)();
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType,
         int pack_size>
inline GPU(Error_t) TryDispatchLaunchLayerNormGradBlockUncachedImplBlockSize(
    GPU(Stream_t) stream, LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy, STORE store,
    const ComputeType* mean, const ComputeType* inv_variance, const int64_t rows,
    const int64_t cols) {
  int max_active_blocks = 0;
  constexpr int block_size_conf_1 = 1024;
  {
    GPU(Error_t) err = GPU(OccupancyMaxActiveBlocksPerMultiprocessor)(
        &max_active_blocks,
        LayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                       block_size_conf_1>,
        block_size_conf_1, 0);
    if (max_active_blocks > 0) {
      return LaunchLayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType,
                                                  pack_size, block_size_conf_1>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
    }
  }
  constexpr int block_size_conf_2 = 512;
  {
    GPU(Error_t) err = GPU(OccupancyMaxActiveBlocksPerMultiprocessor)(
        &max_active_blocks,
        LayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                       block_size_conf_2>,
        block_size_conf_2, 0);
    if (max_active_blocks > 0) {
      return LaunchLayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType,
                                                  pack_size, block_size_conf_2>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
    }
  }
  constexpr int block_size_conf_3 = 256;
  {
    GPU(Error_t) err = GPU(OccupancyMaxActiveBlocksPerMultiprocessor)(
        &max_active_blocks,
        LayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                       block_size_conf_3>,
        block_size_conf_2, 0);
    if (max_active_blocks > 0) {
      return LaunchLayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType,
                                                  pack_size, block_size_conf_3>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
    }
  }
  constexpr int block_size_conf_4 = 128;
  return LaunchLayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType, pack_size,
                                              block_size_conf_4>(
      stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
struct DispatchLayerNormGradBlockUncachedImplPackSize {
  GPU(Error_t) operator()(GPU(Stream_t) stream, LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy,
                         STORE store, const ComputeType* mean, const ComputeType* inv_variance,
                         const int64_t rows, const int64_t cols) {
    if (cols % 2 == 0 && CanPackAs<LOAD_X>(load_x, 2)
        && CanPackAs<LOAD_SCALED_DY>(load_scaled_dy, 2) && CanPackAs<STORE>(store, 2)
        && cols > kWarpSize) {
      return TryDispatchLaunchLayerNormGradBlockUncachedImplBlockSize<LOAD_X, LOAD_SCALED_DY, STORE,
                                                                      ComputeType, 2>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
    } else {
      return TryDispatchLaunchLayerNormGradBlockUncachedImplBlockSize<LOAD_X, LOAD_SCALED_DY, STORE,
                                                                      ComputeType, 1>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
    }
  }
};

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
inline GPU(Error_t) DispatchLayerNormGradBlockUncachedImpl(GPU(Stream_t) stream, LOAD_X load_x,
                                                          LOAD_SCALED_DY load_scaled_dy,
                                                          STORE store, const ComputeType* mean,
                                                          const ComputeType* inv_variance,
                                                          const int64_t rows, const int64_t cols) {
  return DispatchLayerNormGradBlockUncachedImplPackSize<LOAD_X, LOAD_SCALED_DY, STORE,
                                                        ComputeType>()(
      stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
inline typename std::enable_if<!std::is_same<ComputeType, double>::value, GPU(Error_t)>::type
DispatchLayerNormGrad(GPU(Stream_t) stream, LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy,
                      STORE store, const ComputeType* mean, const ComputeType* inv_variance,
                      const int64_t rows, const int64_t cols) {
  if (cols <= 1024) {
    return DispatchLayerNormGradWarpImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType>(
        stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
  } else {
    bool dispatch_smem_impl_success;
    {
      GPU(Error_t) err =
          TryDispatchLayerNormGradBlockSMemImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType>(
              stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols,
              &dispatch_smem_impl_success);
      if (err != GPU(Success)) { return err; }
    }
    if (!dispatch_smem_impl_success) {
      return DispatchLayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType>(
          stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
    }
    return GPU(Success);
  }
}

template<typename LOAD_X, typename LOAD_SCALED_DY, typename STORE, typename ComputeType>
inline typename std::enable_if<std::is_same<ComputeType, double>::value, GPU(Error_t)>::type
DispatchLayerNormGrad(GPU(Stream_t) stream, LOAD_X load_x, LOAD_SCALED_DY load_scaled_dy,
                      STORE store, const ComputeType* mean, const ComputeType* inv_variance,
                      const int64_t rows, const int64_t cols) {
  return DispatchLayerNormGradBlockUncachedImpl<LOAD_X, LOAD_SCALED_DY, STORE, ComputeType>(
      stream, load_x, load_scaled_dy, store, mean, inv_variance, rows, cols);
}

}  // namespace layer_norm

}  // namespace cuda

}  // namespace oneflow

#endif  // ONEFLOW_CORE_CUDA_LAYER_NORM_H_
