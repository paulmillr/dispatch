// Linux helpers are built on macOS, which has no Linux libc headers (PROVENANCE.md): what zstd calls of string.h.
// The static musl libc that Rust's musl targets link supplies them.
#pragma once
#include <stddef.h>
void *memcpy(void *, const void *, size_t);
void *memmove(void *, const void *, size_t);
void *memset(void *, int, size_t);
int memcmp(const void *, const void *, size_t);
