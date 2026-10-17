/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under both the BSD-style license (found in the
 * LICENSE file in the root directory of this source tree) and the GPLv2 (found
 * in the COPYING file in the root directory of this source tree).
 * You may select, at your option, one of the above-listed licenses.
 */

#ifndef ZSTD_PORTABILITY_MACROS_H
#define ZSTD_PORTABILITY_MACROS_H

/**
 * This header file contains macro definitions to support portability.
 * It MUST only contain macro definitions. It MUST not contain any C code.
 *
 * This header ONLY defines macros to detect platforms/feature support.
 *
 */


/* compat. with non-clang compilers */
#ifndef __has_attribute
  #define __has_attribute(x) 0
#endif

/* compat. with non-clang compilers */
#ifndef __has_builtin
#  define __has_builtin(x) 0
#endif

/* compat. with non-clang compilers */
#ifndef __has_feature
#  define __has_feature(x) 0
#endif

/* detects whether we are being compiled under msan */
#ifndef ZSTD_MEMORY_SANITIZER
#  if __has_feature(memory_sanitizer)
#    define ZSTD_MEMORY_SANITIZER 1
#  else
#    define ZSTD_MEMORY_SANITIZER 0
#  endif
#endif

/* detects whether we are being compiled under asan */
#ifndef ZSTD_ADDRESS_SANITIZER
#  if __has_feature(address_sanitizer)
#    define ZSTD_ADDRESS_SANITIZER 1
#  elif defined(__SANITIZE_ADDRESS__)
#    define ZSTD_ADDRESS_SANITIZER 1
#  else
#    define ZSTD_ADDRESS_SANITIZER 0
#  endif
#endif

/* detects whether we are being compiled under dfsan */
#ifndef ZSTD_DATAFLOW_SANITIZER
# if __has_feature(dataflow_sanitizer)
#  define ZSTD_DATAFLOW_SANITIZER 1
# else
#  define ZSTD_DATAFLOW_SANITIZER 0
# endif
#endif

/* Compile time determination of BMI2 support */
#ifndef STATIC_BMI2
#  if defined(__BMI2__)
#    define STATIC_BMI2 1
#  endif
#endif

#ifndef STATIC_BMI2
#  define STATIC_BMI2 0
#endif


#endif /* ZSTD_PORTABILITY_MACROS_H */
