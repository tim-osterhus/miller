// Adapted from owner-authored Cortana wakeword source at commit
// 8f4af867c575c089f45a8df4768663a521f88203.
#include "SherpaONNXBridge.h"

#if !defined(MILLER_WAKEWORD_INPUTS_UNAVAILABLE)
#include <sherpa-onnx/c-api/c-api.h>
#include <stdlib.h>
#include <string.h>

struct MWWSherpaHandle {
  const SherpaOnnxKeywordSpotter *spotter;
  const SherpaOnnxOnlineStream *stream;
};

static void MWWDestroySpotter(const SherpaOnnxKeywordSpotter *spotter) {
  if (spotter == NULL) return;
  try {
    SherpaOnnxDestroyKeywordSpotter(spotter);
  } catch (...) {
  }
}

static void MWWDestroyStream(const SherpaOnnxOnlineStream *stream) {
  if (stream == NULL) return;
  try {
    SherpaOnnxDestroyOnlineStream(stream);
  } catch (...) {
  }
}

MWWSherpaHandle *MWWSherpaCreate(
    const char *encoder,
    const char *decoder,
    const char *joiner,
    const char *tokens,
    const char *keywords,
    float keywords_score,
    float keywords_threshold) {
  const SherpaOnnxKeywordSpotter *spotter = NULL;
  const SherpaOnnxOnlineStream *stream = NULL;
  try {
    SherpaOnnxKeywordSpotterConfig config;
    memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    config.model_config.transducer.encoder = encoder;
    config.model_config.transducer.decoder = decoder;
    config.model_config.transducer.joiner = joiner;
    config.model_config.tokens = tokens;
    config.model_config.num_threads = 1;
    config.model_config.provider = "cpu";
    config.max_active_paths = 4;
    config.num_trailing_blanks = 1;
    config.keywords_score = keywords_score;
    config.keywords_threshold = keywords_threshold;
    config.keywords_file = keywords;

    spotter = SherpaOnnxCreateKeywordSpotter(&config);
    if (spotter == NULL) return NULL;
    stream = SherpaOnnxCreateKeywordStream(spotter);
    if (stream == NULL) {
      MWWDestroySpotter(spotter);
      return NULL;
    }

    MWWSherpaHandle *handle =
        (MWWSherpaHandle *)calloc(1, sizeof(*handle));
    if (handle == NULL) {
      MWWDestroyStream(stream);
      MWWDestroySpotter(spotter);
      return NULL;
    }
    handle->spotter = spotter;
    handle->stream = stream;
    return handle;
  } catch (...) {
    MWWDestroyStream(stream);
    MWWDestroySpotter(spotter);
    return NULL;
  }
}

int32_t MWWSherpaAccept(
    MWWSherpaHandle *handle,
    const float *samples,
    int32_t count) {
  if (handle == NULL || samples == NULL || count <= 0) return -1;
  try {
    SherpaOnnxOnlineStreamAcceptWaveform(
        handle->stream,
        16000,
        samples,
        count
    );
    bool detected = false;
    while (SherpaOnnxIsKeywordStreamReady(
        handle->spotter,
        handle->stream
    )) {
      SherpaOnnxDecodeKeywordStream(handle->spotter, handle->stream);
      const SherpaOnnxKeywordResult *result =
          SherpaOnnxGetKeywordResult(handle->spotter, handle->stream);
      if (result != NULL) {
        detected =
            detected ||
            (result->keyword != NULL && result->keyword[0] != '\0');
        SherpaOnnxDestroyKeywordResult(result);
      }
      if (detected) {
        SherpaOnnxResetKeywordStream(handle->spotter, handle->stream);
      }
    }
    return detected ? 1 : 0;
  } catch (...) {
    return -1;
  }
}

void MWWSherpaReset(MWWSherpaHandle *handle) {
  if (handle == NULL) return;
  try {
    SherpaOnnxResetKeywordStream(handle->spotter, handle->stream);
  } catch (...) {
  }
}

void MWWSherpaDestroy(MWWSherpaHandle *handle) {
  if (handle == NULL) return;
  MWWDestroyStream(handle->stream);
  MWWDestroySpotter(handle->spotter);
  free(handle);
}
#else
struct MWWSherpaHandle {};

MWWSherpaHandle *MWWSherpaCreate(
    const char *,
    const char *,
    const char *,
    const char *,
    const char *,
    float,
    float) {
  return nullptr;
}

int32_t MWWSherpaAccept(MWWSherpaHandle *, const float *, int32_t) {
  return -1;
}

void MWWSherpaReset(MWWSherpaHandle *) {}
void MWWSherpaDestroy(MWWSherpaHandle *) {}
#endif
