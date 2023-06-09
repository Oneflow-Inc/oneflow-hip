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
#ifndef ONEFLOW_CORE_HARDWARE_CUDA_DEVICE_DESCRIPTOR_H_
#define ONEFLOW_CORE_HARDWARE_CUDA_DEVICE_DESCRIPTOR_H_

#include "oneflow/core/hardware/device_descriptor.h"
#include "oneflow/core/common/util.h"
#include <string>
#include <memory>

#if defined(WITH_CUDA) || defined(WITH_ROCM)

namespace oneflow {

namespace hardware {

constexpr char kCudaDeviceDescriptorClassName[] = "cuda";

class CudaDeviceDescriptor : public DeviceDescriptor {
 public:
  OF_DISALLOW_COPY_AND_MOVE(CudaDeviceDescriptor);
  ~CudaDeviceDescriptor() override;

  int32_t Ordinal() const;
  const std::string& Name() const;
  size_t GlobalMemorySizeBytes() const;
  int32_t ClockRateKHz() const;
  int32_t ComputeCapabilityMajor() const;
  int32_t ComputeCapabilityMinor() const;
  int32_t MemoryClockRateKHz() const;
  int32_t MemoryBusWidthBit() const;
  const std::string& PCIBusID() const;
  void Serialize(std::string* serialized) const;
  static std::shared_ptr<const CudaDeviceDescriptor> Query(int32_t ordinal);
  static std::shared_ptr<const CudaDeviceDescriptor> Deserialize(const std::string& serialized);

 private:
  CudaDeviceDescriptor();

  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace hardware

}  // namespace oneflow

#endif  // WITH_CUDA

#endif  // ONEFLOW_CORE_HARDWARE_CUDA_DEVICE_DESCRIPTOR_H_
