// Linux helpers are built on macOS, which has no Linux libc headers (PROVENANCE.md): what zstd calls of stdlib.h.
// The static musl libc that Rust's musl targets link supplies them.
#pragma once
#include <stddef.h>
void *malloc(size_t);
void *calloc(size_t, size_t);
void free(void *);
