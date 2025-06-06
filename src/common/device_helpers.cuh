/**
 * Copyright 2017-2024, XGBoost contributors
 */
#pragma once
#include <thrust/binary_search.h>                       // thrust::upper_bound
#include <thrust/device_ptr.h>                          // for device_ptr
#include <thrust/device_vector.h>                       // for device_vector
#include <thrust/execution_policy.h>                    // thrust::seq
#include <thrust/iterator/discard_iterator.h>           // for discard_iterator
#include <thrust/iterator/transform_output_iterator.h>  // make_transform_output_iterator
#include <thrust/system/cuda/error.h>
#include <thrust/system_error.h>
#include <thrust/unique.h>

#include <algorithm>
#include <cstddef>  // for size_t
#include <cub/cub.cuh>
#include <cub/util_type.cuh>  // for UnitWord, DoubleBuffer
#include <variant>            // for variant, visit
#include <vector>             // for vector

#include "common.h"
#include "cuda_rt_utils.h"  // for GetNumaId, CurrentDevice
#include "device_vector.cuh"
#include "xgboost/host_device_vector.h"
#include "xgboost/logging.h"
#include "xgboost/span.h"

#if defined(XGBOOST_USE_RMM)
#include <rmm/exec_policy.hpp>
#endif  // defined(XGBOOST_USE_RMM)

#if !defined(__CUDA_ARCH__) || __CUDA_ARCH__ >= 600 || defined(__clang__)

#else  // In device code and CUDA < 600
__device__ __forceinline__ double atomicAdd(double* address, double val) {  // NOLINT
  unsigned long long int* address_as_ull =
      (unsigned long long int*)address;                   // NOLINT
  unsigned long long int old = *address_as_ull, assumed;  // NOLINT

  do {
    assumed = old;
    old = atomicCAS(address_as_ull, assumed,
                    __double_as_longlong(val + __longlong_as_double(assumed)));

    // Note: uses integer comparison to avoid hang in case of NaN (since NaN !=
    // NaN)
  } while (assumed != old);

  return __longlong_as_double(old);
}
#endif

namespace dh {

// FIXME(jiamingy): Remove this once we get rid of cub submodule.
constexpr bool BuildWithCUDACub() {
#if defined(THRUST_IGNORE_CUB_VERSION_CHECK) && THRUST_IGNORE_CUB_VERSION_CHECK == 1
  return false;
#else
  return true;
#endif // defined(THRUST_IGNORE_CUB_VERSION_CHECK) && THRUST_IGNORE_CUB_VERSION_CHECK == 1
}

namespace detail {
template <size_t size>
struct AtomicDispatcher;

template <>
struct AtomicDispatcher<sizeof(uint32_t)> {
  using Type = unsigned int;  // NOLINT
  static_assert(sizeof(Type) == sizeof(uint32_t), "Unsigned should be of size 32 bits.");
};

template <>
struct AtomicDispatcher<sizeof(uint64_t)> {
  using Type = unsigned long long;  // NOLINT
  static_assert(sizeof(Type) == sizeof(uint64_t), "Unsigned long long should be of size 64 bits.");
};
}  // namespace detail
}  // namespace dh

// atomicAdd is not defined for size_t.
template <typename T = size_t,
          std::enable_if_t<std::is_same_v<size_t, T> &&
                           !std::is_same_v<size_t, unsigned long long>> * =  // NOLINT
              nullptr>
XGBOOST_DEV_INLINE T atomicAdd(T *addr, T v) {  // NOLINT
  using Type = typename dh::detail::AtomicDispatcher<sizeof(T)>::Type;
  Type ret = ::atomicAdd(reinterpret_cast<Type *>(addr), static_cast<Type>(v));
  return static_cast<T>(ret);
}
namespace dh {

inline int32_t CudaGetPointerDevice(void const *ptr) {
  if (!ptr) {
    return -1;
  }
  int32_t device = -1;
  cudaPointerAttributes attr;
  dh::safe_cuda(cudaPointerGetAttributes(&attr, ptr));
  device = attr.device;
  return device;
}

inline size_t AvailableMemory(int device_idx) {
  size_t device_free = 0;
  size_t device_total = 0;
  safe_cuda(cudaSetDevice(device_idx));
  dh::safe_cuda(cudaMemGetInfo(&device_free, &device_total));
  return device_free;
}

inline int32_t CurrentDevice() {
  int32_t device = 0;
  safe_cuda(cudaGetDevice(&device));
  return device;
}

// Helper function to get a device from a potentially CPU context.
inline auto GetDevice(xgboost::Context const *ctx) {
  auto d = (ctx->IsCUDA()) ? ctx->Device() : xgboost::DeviceOrd::CUDA(::xgboost::curt::CurrentDevice());
  CHECK(!d.IsCPU());
  return d;
}

/**
 * \fn  inline int MaxSharedMemory(int device_idx)
 *
 * \brief Maximum shared memory per block on this device.
 *
 * \param device_idx  Zero-based index of the device.
 */

inline size_t MaxSharedMemory(int device_idx) {
  int max_shared_memory = 0;
  dh::safe_cuda(cudaDeviceGetAttribute
                (&max_shared_memory, cudaDevAttrMaxSharedMemoryPerBlock,
                 device_idx));
  return static_cast<std::size_t>(max_shared_memory);
}

/**
 * \fn  inline int MaxSharedMemoryOptin(int device_idx)
 *
 * \brief Maximum dynamic shared memory per thread block on this device
     that can be opted into when using cudaFuncSetAttribute().
 *
 * \param device_idx  Zero-based index of the device.
 */

inline size_t MaxSharedMemoryOptin(int device_idx) {
  int max_shared_memory = 0;
  dh::safe_cuda(cudaDeviceGetAttribute
                (&max_shared_memory, cudaDevAttrMaxSharedMemoryPerBlockOptin,
                 device_idx));
  return static_cast<std::size_t>(max_shared_memory);
}

XGBOOST_DEV_INLINE void AtomicOrByte(unsigned int *__restrict__ buffer,
                                     size_t ibyte, unsigned char b) {
  atomicOr(&buffer[ibyte / sizeof(unsigned int)],
           static_cast<unsigned int>(b)
               << (ibyte % (sizeof(unsigned int)) * 8));
}

template <typename T>
__device__ xgboost::common::Range GridStrideRange(T begin, T end) {
  begin += blockDim.x * blockIdx.x + threadIdx.x;
  xgboost::common::Range r(begin, end);
  r.Step(gridDim.x * blockDim.x);
  return r;
}

template <typename T>
__device__ xgboost::common::Range BlockStrideRange(T begin, T end) {
  begin += threadIdx.x;
  xgboost::common::Range r(begin, end);
  r.Step(blockDim.x);
  return r;
}

// Threadblock iterates over range, filling with value. Requires all threads in
// block to be active.
template <typename IterT, typename ValueT>
__device__ void BlockFill(IterT begin, size_t n, ValueT value) {
  for (auto i : BlockStrideRange(static_cast<size_t>(0), n)) {
    begin[i] = value;
  }
}

/*
 * Kernel launcher
 */

template <typename L>
__global__ void LaunchNKernel(size_t begin, size_t end, L lambda) {
  for (auto i : GridStrideRange(begin, end)) {
    lambda(i);
  }
}

/* \brief A wrapper around kernel launching syntax, used to guard against empty input.
 *
 * - nvcc fails to deduce template argument when kernel is a template accepting __device__
 *   function as argument.  Hence functions like `LaunchN` cannot use this wrapper.
 *
 * - With c++ initialization list `{}` syntax, you are forced to comply with the CUDA type
 *   specification.
 */
class LaunchKernel {
  size_t shmem_size_;
  cudaStream_t stream_;

  dim3 grids_;
  dim3 blocks_;

 public:
  LaunchKernel(uint32_t _grids, uint32_t _blk, size_t _shmem=0, cudaStream_t _s=nullptr) :
      grids_{_grids, 1, 1}, blocks_{_blk, 1, 1}, shmem_size_{_shmem}, stream_{_s} {}
  LaunchKernel(dim3 _grids, dim3 _blk, size_t _shmem=0, cudaStream_t _s=nullptr) :
      grids_{_grids}, blocks_{_blk}, shmem_size_{_shmem}, stream_{_s} {}

  template <typename K, typename... Args>
  void operator()(K kernel, Args... args) {
    if (XGBOOST_EXPECT(grids_.x * grids_.y * grids_.z == 0, false)) {
      LOG(DEBUG) << "Skipping empty CUDA kernel.";
      return;
    }
    kernel<<<grids_, blocks_, shmem_size_, stream_>>>(args...);  // NOLINT
  }
};

template <int ITEMS_PER_THREAD = 8, int BLOCK_THREADS = 256, typename L>
inline void LaunchN(size_t n, cudaStream_t stream, L lambda) {
  if (n == 0) {
    return;
  }
  const int GRID_SIZE =
      static_cast<int>(xgboost::common::DivRoundUp(n, ITEMS_PER_THREAD * BLOCK_THREADS));
  LaunchNKernel<<<GRID_SIZE, BLOCK_THREADS, 0, stream>>>(  // NOLINT
      static_cast<size_t>(0), n, lambda);
}

// Default stream version
template <int ITEMS_PER_THREAD = 8, int BLOCK_THREADS = 256, typename L>
inline void LaunchN(size_t n, L lambda) {
  LaunchN<ITEMS_PER_THREAD, BLOCK_THREADS>(n, nullptr, lambda);
}

template <typename Container>
void Iota(Container array, cudaStream_t stream) {
  LaunchN(array.size(), stream, [=] __device__(size_t i) { array[i] = i; });
}

// dh::DebugSyncDevice(__FILE__, __LINE__);
inline void DebugSyncDevice(char const *file = __builtin_FILE(), int32_t line = __builtin_LINE()) {
  {
    auto err = cudaDeviceSynchronize();
    ThrowOnCudaError(err, file, line);
  }
  {
    auto err = cudaGetLastError();
    ThrowOnCudaError(err, file, line);
  }
}

// Faster to instantiate than caching_device_vector and invokes no synchronisation
// Use this where vector functionality (e.g. resize) is not required
template <typename T>
class TemporaryArray {
 public:
  using AllocT = XGBCachingDeviceAllocator<T>;
  using value_type = T;  // NOLINT
  explicit TemporaryArray(size_t n) : size_(n) { ptr_ = AllocT().allocate(n); }
  TemporaryArray(size_t n, T val) : size_(n) {
    ptr_ = AllocT().allocate(n);
    this->fill(val);
  }
  ~TemporaryArray() { AllocT().deallocate(ptr_, this->size()); }
  void fill(T val)  // NOLINT
  {
    int device = 0;
    dh::safe_cuda(cudaGetDevice(&device));
    auto d_data = ptr_.get();
    LaunchN(this->size(), [=] __device__(size_t idx) { d_data[idx] = val; });
  }
  thrust::device_ptr<T> data() { return ptr_; }  // NOLINT
  size_t size() { return size_; }  // NOLINT

 private:
  thrust::device_ptr<T> ptr_;
  size_t size_;
};

/**
 * \brief A double buffer, useful for algorithms like sort.
 */
template <typename T>
class DoubleBuffer {
 public:
  cub::DoubleBuffer<T> buff;
  xgboost::common::Span<T> a, b;
  DoubleBuffer() = default;
  template <typename VectorT>
  DoubleBuffer(VectorT *v1, VectorT *v2) {
    a = xgboost::common::Span<T>(v1->data().get(), v1->size());
    b = xgboost::common::Span<T>(v2->data().get(), v2->size());
    buff = cub::DoubleBuffer<T>(a.data(), b.data());
  }

  size_t Size() const {
    CHECK_EQ(a.size(), b.size());
    return a.size();
  }
  cub::DoubleBuffer<T> &CubBuffer() { return buff; }

  T *Current() { return buff.Current(); }
  xgboost::common::Span<T> CurrentSpan() {
    return xgboost::common::Span<T>{buff.Current(), Size()};
  }

  T *Other() { return buff.Alternate(); }
};

template <typename T>
xgboost::common::Span<T> LazyResize(xgboost::Context const *ctx,
                                    xgboost::HostDeviceVector<T> *buffer, std::size_t n) {
  buffer->SetDevice(ctx->Device());
  if (buffer->Size() < n) {
    buffer->Resize(n);
  }
  return buffer->DeviceSpan().subspan(0, n);
}

/**
 * \brief Copies device span to std::vector.
 *
 * \tparam  T Generic type parameter.
 * \param [in,out]  dst Copy destination.
 * \param           src Copy source. Must be device memory.
 */
template <typename T>
void CopyDeviceSpanToVector(std::vector<T> *dst, xgboost::common::Span<T> src) {
  CHECK_EQ(dst->size(), src.size());
  dh::safe_cuda(cudaMemcpyAsync(dst->data(), src.data(), dst->size() * sizeof(T),
                                cudaMemcpyDeviceToHost));
}

/**
 * \brief Copies const device span to std::vector.
 *
 * \tparam  T Generic type parameter.
 * \param [in,out]  dst Copy destination.
 * \param           src Copy source. Must be device memory.
 */
template <typename T>
void CopyDeviceSpanToVector(std::vector<T> *dst, xgboost::common::Span<const T> src) {
  CHECK_EQ(dst->size(), src.size());
  dh::safe_cuda(cudaMemcpyAsync(dst->data(), src.data(), dst->size() * sizeof(T),
                                cudaMemcpyDeviceToHost));
}

// Keep track of pinned memory allocation
class PinnedMemory {
  std::variant<detail::GrowOnlyPinnedMemoryImpl, detail::GrowOnlyVirtualMemVec> impl_;

 public:
  PinnedMemory();

  template <typename T>
  xgboost::common::Span<T> GetSpan(size_t size) {
    return std::visit([&](auto &&alloc) { return alloc.template GetSpan<T>(size); }, this->impl_);
  }
  template <typename T>
  xgboost::common::Span<T> GetSpan(size_t size, T const &init) {
    auto result = this->GetSpan<T>(size);
    std::fill_n(result.data(), result.size(), init);
    return result;
  }
  // Used for testing.
  [[nodiscard]] bool IsVm() {
    return std::get_if<detail::GrowOnlyVirtualMemVec>(&this->impl_) != nullptr;
  }
};

/*
 *  Utility functions
 */

/**
* @brief Helper function to perform device-wide sum-reduction, returns to the
* host
* @param in the input array to be reduced
* @param nVals number of elements in the input array
*/
template <typename T>
typename std::iterator_traits<T>::value_type SumReduction(T in, int nVals) {
  using ValueT = typename std::iterator_traits<T>::value_type;
  size_t tmpSize {0};
  ValueT *dummy_out = nullptr;
  dh::safe_cuda(cub::DeviceReduce::Sum(nullptr, tmpSize, in, dummy_out, nVals));

  TemporaryArray<char> temp(tmpSize + sizeof(ValueT));
  auto ptr = reinterpret_cast<ValueT *>(temp.data().get()) + 1;
  dh::safe_cuda(cub::DeviceReduce::Sum(
      reinterpret_cast<void *>(ptr), tmpSize, in,
      reinterpret_cast<ValueT *>(temp.data().get()),
      nVals));
  ValueT sum;
  dh::safe_cuda(cudaMemcpy(&sum, temp.data().get(), sizeof(ValueT),
                           cudaMemcpyDeviceToHost));
  return sum;
}

constexpr std::pair<int, int> CUDAVersion() {
#if defined(__CUDACC_VER_MAJOR__)
  return std::make_pair(__CUDACC_VER_MAJOR__, __CUDACC_VER_MINOR__);
#else
  // clang/clang-tidy
  return std::make_pair((CUDA_VERSION) / 1000, (CUDA_VERSION) % 100 / 10);
#endif  // defined(__CUDACC_VER_MAJOR__)
}

constexpr std::pair<int32_t, int32_t> ThrustVersion() {
  return std::make_pair(THRUST_MAJOR_VERSION, THRUST_MINOR_VERSION);
}
// Whether do we have thrust 1.x with x >= minor
template <int32_t minor>
constexpr bool HasThrustMinorVer() {
  return (ThrustVersion().first == 1 && ThrustVersion().second >= minor) ||
         ThrustVersion().first > 1;
}

namespace detail {
template <typename T>
using TypedDiscardCTK114 = thrust::discard_iterator<T>;

template <typename T>
class TypedDiscard : public thrust::discard_iterator<T> {
 public:
  using value_type = T;  // NOLINT
};
} // namespace detail

template <typename T>
using TypedDiscard = std::conditional_t<HasThrustMinorVer<12>(), detail::TypedDiscardCTK114<T>,
                                        detail::TypedDiscard<T>>;

template <typename VectorT, typename T = typename VectorT::value_type,
          typename IndexT = typename xgboost::common::Span<T>::index_type>
xgboost::common::Span<T> ToSpan(VectorT &vec, IndexT offset = 0,
                                IndexT size = std::numeric_limits<size_t>::max()) {
  size = size == std::numeric_limits<size_t>::max() ? vec.size() : size;
  CHECK_LE(offset + size, vec.size());
  return {thrust::raw_pointer_cast(vec.data()) + offset, size};
}

template <typename T>
xgboost::common::Span<T> ToSpan(device_vector<T> &vec, size_t offset, size_t size) {
  return ToSpan(vec, offset, size);
}

template <typename T>
xgboost::common::Span<std::add_const_t<T>> ToSpan(device_vector<T> const &vec) {
  return {thrust::raw_pointer_cast(vec.data()), vec.size()};
}

template <typename T>
xgboost::common::Span<T> ToSpan(DeviceUVector<T> &vec) {
  return {vec.data(), vec.size()};
}

template <typename T>
xgboost::common::Span<std::add_const_t<T>> ToSpan(DeviceUVector<T> const &vec) {
  return {vec.data(), vec.size()};
}

// thrust begin, similiar to std::begin
template <typename T>
thrust::device_ptr<T> tbegin(xgboost::HostDeviceVector<T>& vector) {  // NOLINT
  return thrust::device_ptr<T>(vector.DevicePointer());
}

template <typename T>
thrust::device_ptr<T> tend(xgboost::HostDeviceVector<T>& vector) {  // // NOLINT
  return tbegin(vector) + vector.Size();
}

template <typename T>
thrust::device_ptr<T const> tcbegin(xgboost::HostDeviceVector<T> const& vector) {  // NOLINT
  return thrust::device_ptr<T const>(vector.ConstDevicePointer());
}

template <typename T>
thrust::device_ptr<T const> tcend(xgboost::HostDeviceVector<T> const& vector) {  // NOLINT
  return tcbegin(vector) + vector.Size();
}

template <typename T>
XGBOOST_DEVICE thrust::device_ptr<T> tbegin(xgboost::common::Span<T>& span) {  // NOLINT
  return thrust::device_ptr<T>(span.data());
}

template <typename T>
XGBOOST_DEVICE thrust::device_ptr<T> tbegin(xgboost::common::Span<T> const& span) {  // NOLINT
  return thrust::device_ptr<T>(span.data());
}

template <typename T>
XGBOOST_DEVICE thrust::device_ptr<T> tend(xgboost::common::Span<T>& span) {  // NOLINT
  return tbegin(span) + span.size();
}

template <typename T>
XGBOOST_DEVICE thrust::device_ptr<T> tend(xgboost::common::Span<T> const& span) {  // NOLINT
  return tbegin(span) + span.size();
}

template <typename T>
XGBOOST_DEVICE auto trbegin(xgboost::common::Span<T> &span) {  // NOLINT
  return thrust::make_reverse_iterator(span.data() + span.size());
}

template <typename T>
XGBOOST_DEVICE auto trend(xgboost::common::Span<T> &span) {  // NOLINT
  return trbegin(span) + span.size();
}

template <typename T>
XGBOOST_DEVICE thrust::device_ptr<T const> tcbegin(xgboost::common::Span<T> const& span) {  // NOLINT
  return thrust::device_ptr<T const>(span.data());
}

template <typename T>
XGBOOST_DEVICE thrust::device_ptr<T const> tcend(xgboost::common::Span<T> const& span) {  // NOLINT
  return tcbegin(span) + span.size();
}

template <typename T>
XGBOOST_DEVICE auto tcrbegin(xgboost::common::Span<T> const &span) {  // NOLINT
  return thrust::make_reverse_iterator(span.data() + span.size());
}

template <typename T>
XGBOOST_DEVICE auto tcrend(xgboost::common::Span<T> const &span) {  // NOLINT
  return tcrbegin(span) + span.size();
}

// Atomic add function for gradients
template <typename OutputGradientT, typename InputGradientT>
XGBOOST_DEV_INLINE void AtomicAddGpair(OutputGradientT* dest,
                                       const InputGradientT& gpair) {
  auto dst_ptr = reinterpret_cast<typename OutputGradientT::ValueT*>(dest);

  atomicAdd(dst_ptr,
            static_cast<typename OutputGradientT::ValueT>(gpair.GetGrad()));
  atomicAdd(dst_ptr + 1,
            static_cast<typename OutputGradientT::ValueT>(gpair.GetHess()));
}


// Thrust version of this function causes error on Windows
template <typename ReturnT, typename IterT, typename FuncT>
XGBOOST_DEVICE thrust::transform_iterator<FuncT, IterT, ReturnT> MakeTransformIterator(
  IterT iter, FuncT func) {
  return thrust::transform_iterator<FuncT, IterT, ReturnT>(iter, func);
}

template <typename It>
size_t XGBOOST_DEVICE SegmentId(It first, It last, size_t idx) {
  size_t segment_id = thrust::upper_bound(thrust::seq, first, last, idx) - 1 - first;
  return segment_id;
}

template <typename T>
size_t XGBOOST_DEVICE SegmentId(xgboost::common::Span<T> segments_ptr, size_t idx) {
  return SegmentId(segments_ptr.cbegin(), segments_ptr.cend(), idx);
}

namespace detail {
template <typename Key, typename KeyOutIt>
struct SegmentedUniqueReduceOp {
  KeyOutIt key_out;
  __device__ Key const& operator()(Key const& key) const {
    auto constexpr kOne = static_cast<std::remove_reference_t<decltype(*(key_out + key.first))>>(1);
    atomicAdd(&(*(key_out + key.first)), kOne);
    return key;
  }
};
}  // namespace detail

/* \brief Segmented unique function.  Keys are pointers to segments with key_segments_last -
 *        key_segments_first = n_segments + 1.
 *
 * \pre   Input segment and output segment must not overlap.
 *
 * \param key_segments_first Beginning iterator of segments.
 * \param key_segments_last  End iterator of segments.
 * \param val_first          Beginning iterator of values.
 * \param val_last           End iterator of values.
 * \param key_segments_out   Output iterator of segments.
 * \param val_out            Output iterator of values.
 *
 * \return Number of unique values in total.
 */
template <typename DerivedPolicy, typename KeyInIt, typename KeyOutIt, typename ValInIt,
          typename ValOutIt, typename CompValue, typename CompKey = thrust::equal_to<size_t>>
size_t SegmentedUnique(const thrust::detail::execution_policy_base<DerivedPolicy> &exec,
                       KeyInIt key_segments_first, KeyInIt key_segments_last, ValInIt val_first,
                       ValInIt val_last, KeyOutIt key_segments_out, ValOutIt val_out,
                       CompValue comp, CompKey comp_key = thrust::equal_to<size_t>{}) {
  using Key = thrust::pair<size_t, typename thrust::iterator_traits<ValInIt>::value_type>;
  auto unique_key_it = dh::MakeTransformIterator<Key>(
      thrust::make_counting_iterator(static_cast<size_t>(0)),
      [=] __device__(size_t i) {
        size_t seg = dh::SegmentId(key_segments_first, key_segments_last, i);
        return thrust::make_pair(seg, *(val_first + i));
      });
  size_t segments_len = key_segments_last - key_segments_first;
  thrust::fill(exec, key_segments_out, key_segments_out + segments_len, 0);
  size_t n_inputs = std::distance(val_first, val_last);
  // Reduce the number of uniques elements per segment, avoid creating an intermediate
  // array for `reduce_by_key`.  It's limited by the types that atomicAdd supports.  For
  // example, size_t is not supported as of CUDA 10.2.
  auto reduce_it = thrust::make_transform_output_iterator(
      thrust::make_discard_iterator(),
      detail::SegmentedUniqueReduceOp<Key, KeyOutIt>{key_segments_out});
  auto uniques_ret = thrust::unique_by_key_copy(
      exec, unique_key_it, unique_key_it + n_inputs,
      val_first, reduce_it, val_out,
      [=] __device__(Key const &l, Key const &r) {
        if (comp_key(l.first, r.first)) {
          // In the same segment.
          return comp(l.second, r.second);
        }
        return false;
      });
  auto n_uniques = uniques_ret.second - val_out;
  CHECK_LE(n_uniques, n_inputs);
  thrust::exclusive_scan(exec, key_segments_out,
                         key_segments_out + segments_len, key_segments_out, 0);
  return n_uniques;
}

/**
 * \brief Unique by key for many groups of data.  Has same constraint as `SegmentedUnique`.
 *
 * \tparam exec               thrust execution policy
 * \tparam key_segments_first start iter to segment pointer
 * \tparam key_segments_last  end iter to segment pointer
 * \tparam key_first          start iter to key for comparison
 * \tparam key_last           end iter to key for comparison
 * \tparam val_first          start iter to values
 * \tparam key_segments_out   output iterator for new segment pointer
 * \tparam val_out            output iterator for values
 * \tparam comp               binary comparison operator
 */
template <typename DerivedPolicy, typename SegInIt, typename SegOutIt,
          typename KeyInIt, typename ValInIt, typename ValOutIt, typename Comp>
size_t SegmentedUniqueByKey(
    const thrust::detail::execution_policy_base<DerivedPolicy> &exec,
    SegInIt key_segments_first, SegInIt key_segments_last, KeyInIt key_first,
    KeyInIt key_last, ValInIt val_first, SegOutIt key_segments_out,
    ValOutIt val_out, Comp comp) {
  using Key =
      thrust::pair<size_t,
                   typename thrust::iterator_traits<KeyInIt>::value_type>;

  auto unique_key_it = dh::MakeTransformIterator<Key>(
      thrust::make_counting_iterator(static_cast<size_t>(0)),
      [=] __device__(size_t i) {
        size_t seg = dh::SegmentId(key_segments_first, key_segments_last, i);
        return thrust::make_pair(seg, *(key_first + i));
      });
  size_t segments_len = key_segments_last - key_segments_first;
  thrust::fill(exec, key_segments_out, key_segments_out + segments_len, 0);
  size_t n_inputs = std::distance(key_first, key_last);
  // Reduce the number of uniques elements per segment, avoid creating an
  // intermediate array for `reduce_by_key`.  It's limited by the types that
  // atomicAdd supports.  For example, size_t is not supported as of CUDA 10.2.
  auto reduce_it = thrust::make_transform_output_iterator(
      thrust::make_discard_iterator(),
      detail::SegmentedUniqueReduceOp<Key, SegOutIt>{key_segments_out});
  auto uniques_ret = thrust::unique_by_key_copy(
      exec, unique_key_it, unique_key_it + n_inputs, val_first, reduce_it,
      val_out, [=] __device__(Key const &l, Key const &r) {
        if (l.first == r.first) {
          // In the same segment.
          return comp(thrust::get<1>(l), thrust::get<1>(r));
        }
        return false;
      });
  auto n_uniques = uniques_ret.second - val_out;
  CHECK_LE(n_uniques, n_inputs);
  thrust::exclusive_scan(exec, key_segments_out,
                         key_segments_out + segments_len, key_segments_out, 0);
  return n_uniques;
}

template <typename Policy, typename InputIt, typename Init, typename Func>
auto Reduce(Policy policy, InputIt first, InputIt second, Init init, Func reduce_op) {
  size_t constexpr kLimit = std::numeric_limits<int32_t>::max() / 2;
  size_t size = std::distance(first, second);
  using Ty = std::remove_cv_t<Init>;
  Ty aggregate = init;
  for (size_t offset = 0; offset < size; offset += kLimit) {
    auto begin_it = first + offset;
    auto end_it = first + std::min(offset + kLimit, size);
    size_t batch_size = std::distance(begin_it, end_it);
    CHECK_LE(batch_size, size);
    auto ret = thrust::reduce(policy, begin_it, end_it, init, reduce_op);
    aggregate = reduce_op(aggregate, ret);
  }
  return aggregate;
}

class CUDAStreamView;

class CUDAEvent {
  std::unique_ptr<cudaEvent_t, void (*)(cudaEvent_t *)> event_;

 public:
  explicit CUDAEvent(bool disable_timing = true)
      : event_{[disable_timing] {
                 auto e = new cudaEvent_t;
                 dh::safe_cuda(cudaEventCreateWithFlags(
                     e, disable_timing ? cudaEventDisableTiming : cudaEventDefault));
                 return e;
               }(),
               [](cudaEvent_t *e) {
                 if (e) {
                   dh::safe_cuda(cudaEventDestroy(*e));
                   delete e;
                 }
               }} {}

  inline void Record(CUDAStreamView stream);  // NOLINT
  // Define swap-based ctor to make sure an event is always valid.
  CUDAEvent(CUDAEvent &&e) : CUDAEvent() { std::swap(this->event_, e.event_); }
  CUDAEvent &operator=(CUDAEvent &&e) {
    std::swap(this->event_, e.event_);
    return *this;
  }

  operator cudaEvent_t() const { return *event_; }                // NOLINT
  cudaEvent_t const *data() const { return this->event_.get(); }  // NOLINT
  void Sync() { dh::safe_cuda(cudaEventSynchronize(*this->data())); }
};

class CUDAStreamView {
  cudaStream_t stream_{nullptr};

 public:
  explicit CUDAStreamView(cudaStream_t s) : stream_{s} {}
  void Wait(CUDAEvent const &e) {
#if defined(__CUDACC_VER_MAJOR__)
#if __CUDACC_VER_MAJOR__ == 11 && __CUDACC_VER_MINOR__ == 0
    // CUDA == 11.0
    dh::safe_cuda(cudaStreamWaitEvent(stream_, cudaEvent_t{e}, 0));
#else
    // CUDA > 11.0
    dh::safe_cuda(cudaStreamWaitEvent(stream_, cudaEvent_t{e}, cudaEventWaitDefault));
#endif  // __CUDACC_VER_MAJOR__ == 11 && __CUDACC_VER_MINOR__ == 0:
#else   // clang
    dh::safe_cuda(cudaStreamWaitEvent(stream_, cudaEvent_t{e}, cudaEventWaitDefault));
#endif  //  defined(__CUDACC_VER_MAJOR__)
  }
  operator cudaStream_t() const {  // NOLINT
    return stream_;
  }
  cudaError_t Sync(bool error = true) {
    if (error) {
      dh::safe_cuda(cudaStreamSynchronize(stream_));
      return cudaSuccess;
    }
    return cudaStreamSynchronize(stream_);
  }
};

inline void CUDAEvent::Record(CUDAStreamView stream) {  // NOLINT
  dh::safe_cuda(cudaEventRecord(*event_, cudaStream_t{stream}));
}

// Changing this has effect on prediction return, where we need to pass the pointer to
// third-party libraries like cuPy
inline CUDAStreamView DefaultStream() { return CUDAStreamView{cudaStreamPerThread}; }

class CUDAStream {
  cudaStream_t stream_;

 public:
  CUDAStream() { dh::safe_cuda(cudaStreamCreateWithFlags(&stream_, cudaStreamNonBlocking)); }
  ~CUDAStream() { dh::safe_cuda(cudaStreamDestroy(stream_)); }

  [[nodiscard]] CUDAStreamView View() const { return CUDAStreamView{stream_}; }
  [[nodiscard]] cudaStream_t Handle() const { return stream_; }

  void Sync() { this->View().Sync(); }
  void Wait(CUDAEvent const &e) { this->View().Wait(e); }
};

template <class Src, class Dst>
void CopyTo(Src const &src, Dst *dst, CUDAStreamView stream = DefaultStream()) {
  if (src.empty()) {
    dst->clear();
    return;
  }
  dst->resize(src.size());
  using SVT = std::remove_cv_t<typename Src::value_type>;
  using DVT = std::remove_cv_t<typename Dst::value_type>;
  static_assert(std::is_same_v<SVT, DVT>, "Host and device containers must have same value type.");
  dh::safe_cuda(cudaMemcpyAsync(thrust::raw_pointer_cast(dst->data()), src.data(),
                                src.size() * sizeof(SVT), cudaMemcpyDefault, stream));
}


/**
 * @brief Wrapper for the @ref cudaMemcpyBatchAsync .
 *
 * @param dsts Host pointer to a list of device pointers.
 * @param srcs Host pointer to a list of device pointers.
 * @param sizes Host pointer to a list of sizes.
 * @param count How many batches.
 * @param fail_idx Which batch has failed, if any. When it's assigned to SIZE_MAX, then
 *   it's a general error.
 * @param stream CUDA stream. The wrapper enforces stream order access.
 */
template <cudaMemcpyKind kind, typename T, typename U>
[[nodiscard]] cudaError_t MemcpyBatchAsync(T **dsts, U **srcs, std::size_t const *sizes,
                                           std::size_t count, std::size_t *fail_idx,
                                           cudaStream_t stream) {
#if CUDART_VERSION >= 12080
  static_assert(kind == cudaMemcpyDeviceToHost || kind == cudaMemcpyHostToDevice,
                "Not implemented.");
  cudaMemcpyAttributes attr;
  attr.srcAccessOrder = cudaMemcpySrcAccessOrderStream;
  attr.flags = cudaMemcpyFlagPreferOverlapWithCompute;

  auto assign_host = [](cudaMemLocation *hint) {
    hint->type = cudaMemLocationTypeHostNuma;
    hint->id = xgboost::curt::GetNumaId();
  };
  auto assign_device = [](cudaMemLocation *hint) {
    hint->type = cudaMemLocationTypeDevice;
    hint->id = xgboost::curt::CurrentDevice();
  };
  if constexpr (kind == cudaMemcpyDeviceToHost) {
    assign_device(&attr.srcLocHint);
    assign_host(&attr.dstLocHint);
  } else {
    assign_host(&attr.srcLocHint);
    assign_device(&attr.dstLocHint);
  }
  return cudaMemcpyBatchAsync(dsts, srcs, const_cast<std::size_t *>(sizes), count, attr, fail_idx,
                              stream);
#else
  LOG(FATAL) << "CUDA >= 12.8 is required.";
  return cudaErrorInvalidValue;
#endif  // CUDART_VERSION >= 12080
}

inline auto CachingThrustPolicy() {
  XGBCachingDeviceAllocator<char> alloc;
#if THRUST_MAJOR_VERSION >= 2 || defined(XGBOOST_USE_RMM)
  return thrust::cuda::par_nosync(alloc).on(DefaultStream());
#else
  return thrust::cuda::par(alloc).on(DefaultStream());
#endif  // THRUST_MAJOR_VERSION >= 2 || defined(XGBOOST_USE_RMM)
}

// Force nvcc to load data as constant
template <typename T>
class LDGIterator {
  using DeviceWordT = typename cub::UnitWord<T>::DeviceWord;
  static constexpr std::size_t kNumWords = sizeof(T) / sizeof(DeviceWordT);

  const T *ptr_;

 public:
  XGBOOST_DEVICE explicit LDGIterator(const T *ptr) : ptr_(ptr) {}
  __device__ T operator[](std::size_t idx) const {
    DeviceWordT tmp[kNumWords];
    static_assert(sizeof(tmp) == sizeof(T), "Expect sizes to be equal.");
#pragma unroll
    for (int i = 0; i < kNumWords; i++) {
      tmp[i] = __ldg(reinterpret_cast<const DeviceWordT *>(ptr_ + idx) + i);
    }
    return *reinterpret_cast<const T *>(tmp);
  }
};
}  // namespace dh
