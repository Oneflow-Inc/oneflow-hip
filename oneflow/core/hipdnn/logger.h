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
#ifdef WITH_ROCM

#include <iostream>
#include <sstream>
extern std::ostream cerr;

#if ENABLE_LOG == 0
#define DEBUG_CURRENT_CALL_STACK_LEVEL DEBUG_CALL_STACK_LEVEL_NONE
#endif

#define DEBUG_CALL_STACK_LEVEL_NONE 0
#define DEBUG_CALL_STACK_LEVEL_ERRORS 1
#define DEBUG_CALL_STACK_LEVEL_PROMOTED 2
#define DEBUG_CALL_STACK_LEVEL_INTERNAL_ALLOC 2
#define DEBUG_CALL_STACK_LEVEL_CALLS 3
#define DEBUG_CALL_STACK_LEVEL_MARSHALLING 4
#define DEBUG_CALL_STACK_LEVEL_INFO 5

#ifndef DEBUG_CURRENT_CALL_STACK_LEVEL
#define DEBUG_CURRENT_CALL_STACK_LEVEL DEBUG_CALL_STACK_LEVEL_INFO
#endif

namespace open {

enum class LoggingLevel {
  NONE = 0, // WARNING for Release builds, INFO for Debug builds.
  ERRORS,
  PROMOTED,
  INTERNAL_ALLOC = 2,
  CALLS,
  MARSHALLING = 4,
  INFO = 5
};

int IsLogging(LoggingLevel level);

#define OPEN_LOG(level, ...)                                                   \
  do {                                                                         \
    if (open::IsLogging(level)) {                                              \
      std::cerr << __VA_ARGS__ << std ::endl;                                  \
    }                                                                          \
  } while (false)

#define HIPDNN_OPEN_LOG_E(...) OPEN_LOG(open::LoggingLevel::ERRORS, __VA_ARGS__)
#define HIPDNN_OPEN_LOG_P(...)                                                 \
  OPEN_LOG(open::LoggingLevel::PROMOTED, __VA_ARGS__)
#define HIPDNN_OPEN_LOG_I(...)                                                 \
  OPEN_LOG(open::LoggingLevel::INTERNAL_ALLOC, __VA_ARGS__)
#define HIPDNN_OPEN_LOG_C(...) OPEN_LOG(open::LoggingLevel::CALLS, __VA_ARGS__)
#define HIPDNN_OPEN_LOG_M(...)                                                 \
  OPEN_LOG(open::LoggingLevel::MARSHALLING, __VA_ARGS__)
#define HIPDNN_OPEN_LOG_I2(...) OPEN_LOG(open::LoggingLevel::INFO, __VA_ARGS__)

} // namespace open

#endif //WITH_ROCM
