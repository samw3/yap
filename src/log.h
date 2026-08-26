#pragma once
// os_log is the right sink here: launched via `open`, the app has no stdout.
// Read with: log stream --predicate 'subsystem == "com.samw3.yap"' --style compact
#include <os/log.h>

namespace yap {
inline os_log_t log_handle() {
    static os_log_t h = os_log_create("com.samw3.yap", "yap");
    return h;
}
}  // namespace yap

#define YAP_INFO(fmt, ...)  os_log_info (yap::log_handle(), fmt, ##__VA_ARGS__)
#define YAP_LOG(fmt, ...)   os_log       (yap::log_handle(), fmt, ##__VA_ARGS__)
#define YAP_WARN(fmt, ...)  os_log_error (yap::log_handle(), fmt, ##__VA_ARGS__)
#define YAP_FAULT(fmt, ...) os_log_fault (yap::log_handle(), fmt, ##__VA_ARGS__)
