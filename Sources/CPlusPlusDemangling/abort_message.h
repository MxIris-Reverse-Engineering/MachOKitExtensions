#ifndef CPLUSPLUS_DEMANGLING_ABORT_MESSAGE_H
#define CPLUSPLUS_DEMANGLING_ABORT_MESSAGE_H

// `ItaniumDemangle/DemangleConfig.h` includes "../abort_message.h" from
// libc++abi for the one function it needs, `__abort_message`. This file
// stands in for it, so that the vendored files stay byte-for-byte as libc++abi
// ships them. `static` keeps the definition out of the way of libc++abi's own
// (hidden) `__abort_message` in the same process.

#include <cstdarg>
#include <cstdio>
#include <cstdlib>

__attribute__((format(printf, 1, 2))) [[noreturn]] static inline void __abort_message(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    std::vfprintf(stderr, format, arguments);
    va_end(arguments);
    std::fputc('\n', stderr);
    std::abort();
}

#endif
