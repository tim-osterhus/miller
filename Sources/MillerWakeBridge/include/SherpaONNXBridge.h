// Adapted from owner-authored Cortana wakeword source at commit
// 8f4af867c575c089f45a8df4768663a521f88203.
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MWWSherpaHandle MWWSherpaHandle;

MWWSherpaHandle * _Nullable MWWSherpaCreate(
    const char * _Nonnull encoder,
    const char * _Nonnull decoder,
    const char * _Nonnull joiner,
    const char * _Nonnull tokens,
    const char * _Nonnull keywords,
    float keywords_score,
    float keywords_threshold);
int32_t MWWSherpaAccept(
    MWWSherpaHandle * _Nonnull handle,
    const float * _Nonnull samples,
    int32_t count);
void MWWSherpaReset(MWWSherpaHandle * _Nonnull handle);
void MWWSherpaDestroy(MWWSherpaHandle * _Nullable handle);

#ifdef __cplusplus
}
#endif
