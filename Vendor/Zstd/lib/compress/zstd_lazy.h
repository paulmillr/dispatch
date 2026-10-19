/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under both the BSD-style license (found in the
 * LICENSE file in the root directory of this source tree) and the GPLv2 (found
 * in the COPYING file in the root directory of this source tree).
 * You may select, at your option, one of the above-listed licenses.
 */

#ifndef ZSTD_LAZY_H
#define ZSTD_LAZY_H

#include "zstd_compress_internal.h"

/**
 * Dedicated Dictionary Search Structure bucket log. In the
 * ZSTD_dedicatedDictSearch mode, the hashTable has
 * 2 ** ZSTD_LAZY_DDSS_BUCKET_LOG entries in each bucket, rather than just
 * one.
 */
#define ZSTD_LAZY_DDSS_BUCKET_LOG 2

#define ZSTD_ROW_HASH_TAG_BITS 8        /* nb bits to use for the tag */

U32 ZSTD_insertAndFindFirstIndex(ZSTD_MatchState_t* ms, const BYTE* ip);
void ZSTD_row_update(ZSTD_MatchState_t* const ms, const BYTE* ip);

void ZSTD_dedicatedDictSearch_lazy_loadDictionary(ZSTD_MatchState_t* ms, const BYTE* const ip);

void ZSTD_preserveUnsortedMark (U32* const table, U32 const size, U32 const reducerValue);  /*! used in ZSTD_reduceIndex(). preemptively increase value of ZSTD_DUBT_UNSORTED_MARK */

#define ZSTD_COMPRESSBLOCK_GREEDY NULL
#define ZSTD_COMPRESSBLOCK_GREEDY_ROW NULL
#define ZSTD_COMPRESSBLOCK_GREEDY_DICTMATCHSTATE NULL
#define ZSTD_COMPRESSBLOCK_GREEDY_DICTMATCHSTATE_ROW NULL
#define ZSTD_COMPRESSBLOCK_GREEDY_DEDICATEDDICTSEARCH NULL
#define ZSTD_COMPRESSBLOCK_GREEDY_DEDICATEDDICTSEARCH_ROW NULL
#define ZSTD_COMPRESSBLOCK_GREEDY_EXTDICT NULL
#define ZSTD_COMPRESSBLOCK_GREEDY_EXTDICT_ROW NULL

#define ZSTD_COMPRESSBLOCK_LAZY NULL
#define ZSTD_COMPRESSBLOCK_LAZY_ROW NULL
#define ZSTD_COMPRESSBLOCK_LAZY_DICTMATCHSTATE NULL
#define ZSTD_COMPRESSBLOCK_LAZY_DICTMATCHSTATE_ROW NULL
#define ZSTD_COMPRESSBLOCK_LAZY_DEDICATEDDICTSEARCH NULL
#define ZSTD_COMPRESSBLOCK_LAZY_DEDICATEDDICTSEARCH_ROW NULL
#define ZSTD_COMPRESSBLOCK_LAZY_EXTDICT NULL
#define ZSTD_COMPRESSBLOCK_LAZY_EXTDICT_ROW NULL

size_t ZSTD_compressBlock_lazy2(
        ZSTD_MatchState_t* ms, SeqStore_t* seqStore, U32 rep[ZSTD_REP_NUM],
        void const* src, size_t srcSize);
size_t ZSTD_compressBlock_lazy2_row(
        ZSTD_MatchState_t* ms, SeqStore_t* seqStore, U32 rep[ZSTD_REP_NUM],
        void const* src, size_t srcSize);
size_t ZSTD_compressBlock_lazy2_dictMatchState(
        ZSTD_MatchState_t* ms, SeqStore_t* seqStore, U32 rep[ZSTD_REP_NUM],
        void const* src, size_t srcSize);
size_t ZSTD_compressBlock_lazy2_dictMatchState_row(
        ZSTD_MatchState_t* ms, SeqStore_t* seqStore, U32 rep[ZSTD_REP_NUM],
        void const* src, size_t srcSize);
size_t ZSTD_compressBlock_lazy2_dedicatedDictSearch(
        ZSTD_MatchState_t* ms, SeqStore_t* seqStore, U32 rep[ZSTD_REP_NUM],
        void const* src, size_t srcSize);
size_t ZSTD_compressBlock_lazy2_dedicatedDictSearch_row(
        ZSTD_MatchState_t* ms, SeqStore_t* seqStore, U32 rep[ZSTD_REP_NUM],
        void const* src, size_t srcSize);
size_t ZSTD_compressBlock_lazy2_extDict(
        ZSTD_MatchState_t* ms, SeqStore_t* seqStore, U32 rep[ZSTD_REP_NUM],
        void const* src, size_t srcSize);
size_t ZSTD_compressBlock_lazy2_extDict_row(
        ZSTD_MatchState_t* ms, SeqStore_t* seqStore, U32 rep[ZSTD_REP_NUM],
        void const* src, size_t srcSize);

#define ZSTD_COMPRESSBLOCK_LAZY2 ZSTD_compressBlock_lazy2
#define ZSTD_COMPRESSBLOCK_LAZY2_ROW ZSTD_compressBlock_lazy2_row
#define ZSTD_COMPRESSBLOCK_LAZY2_DICTMATCHSTATE ZSTD_compressBlock_lazy2_dictMatchState
#define ZSTD_COMPRESSBLOCK_LAZY2_DICTMATCHSTATE_ROW ZSTD_compressBlock_lazy2_dictMatchState_row
#define ZSTD_COMPRESSBLOCK_LAZY2_DEDICATEDDICTSEARCH ZSTD_compressBlock_lazy2_dedicatedDictSearch
#define ZSTD_COMPRESSBLOCK_LAZY2_DEDICATEDDICTSEARCH_ROW ZSTD_compressBlock_lazy2_dedicatedDictSearch_row
#define ZSTD_COMPRESSBLOCK_LAZY2_EXTDICT ZSTD_compressBlock_lazy2_extDict
#define ZSTD_COMPRESSBLOCK_LAZY2_EXTDICT_ROW ZSTD_compressBlock_lazy2_extDict_row

#define ZSTD_COMPRESSBLOCK_BTLAZY2 NULL
#define ZSTD_COMPRESSBLOCK_BTLAZY2_DICTMATCHSTATE NULL
#define ZSTD_COMPRESSBLOCK_BTLAZY2_EXTDICT NULL

#endif /* ZSTD_LAZY_H */
