#pragma once
#include <stdint.h>
void test_ufs(void);
/* Write a diagnostic beacon block to userdata. stage=1..N. */
void ufs_beacon(uint32_t stage, uint64_t extra);
