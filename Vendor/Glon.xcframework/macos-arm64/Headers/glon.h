#ifndef GLON_H
#define GLON_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Bounded JSON request/response ABI; see glonOdin/abi/abi.odin. Single-flight:
// the host must serialise every call and must not call from two threads.
uint32_t core_abi_version(void);
void core_init(void);
void *core_reserve(uint32_t length);
// Optional ABI v2 binary payload; reserve after core_reserve, before execute.
void *core_reserve_blob(uint32_t length);
uint32_t core_execute(void);
void *core_response_pointer(void);
uint32_t core_response_length(void);
void core_reset(uint32_t reset_all);
#ifdef __cplusplus
}
#endif
#endif
