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
#ifndef ONEFLOW_CORE_EP_GPU_MACRO_H_
#define ONEFLOW_CORE_EP_GPU_MACRO_H_

#ifdef WITH_ROCM
#define GPU(str) hip##str
void SYNCWARP()
{
    __syncthreads();
}
void TRAP()
{
    asm volatile("s_trap 0;");}
#else
#define GPU(str) cuda##str
void SYNCWARP()
{
    __syncwarp();
}
void TRAP()
{
    __trap();
}
#endif

#endif // ONEFLOW_CORE_EP_GPU_MACRO_H_