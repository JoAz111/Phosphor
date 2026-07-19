#ifndef PHOSPHOR_FFMPEG_H
#define PHOSPHOR_FFMPEG_H

#include <CoreVideo/CoreVideo.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PhosphorFFmpegVideoDecoder PhosphorFFmpegVideoDecoder;
typedef struct PhosphorFFmpegAudioDecoder PhosphorFFmpegAudioDecoder;

typedef struct {
    double duration;
    double nominal_frame_rate;
    int width;
    int height;
    bool is_interlaced;
    bool is_bottom_field_first;
    bool is_hdr;
    bool has_audio;
} PhosphorFFmpegMediaInfo;

PhosphorFFmpegVideoDecoder *phosphor_ffmpeg_video_open(
    const char *path,
    PhosphorFFmpegMediaInfo *info,
    char *error_buffer,
    size_t error_buffer_size
);

void phosphor_ffmpeg_video_close(PhosphorFFmpegVideoDecoder *decoder);

/// Returns 1 for a frame, 0 at end of stream, and -1 on failure. The caller
/// owns the returned pixel buffer and must release it.
int phosphor_ffmpeg_video_read(
    PhosphorFFmpegVideoDecoder *decoder,
    CVPixelBufferRef *pixel_buffer,
    double *presentation_time
);

int phosphor_ffmpeg_video_seek(
    PhosphorFFmpegVideoDecoder *decoder,
    double presentation_time
);

PhosphorFFmpegAudioDecoder *phosphor_ffmpeg_audio_open(
    const char *path,
    char *error_buffer,
    size_t error_buffer_size
);

void phosphor_ffmpeg_audio_close(PhosphorFFmpegAudioDecoder *decoder);

/// Decodes interleaved stereo Float32 PCM at 48 kHz. Returns a frame count,
/// zero at end of stream, or -1 on failure.
int phosphor_ffmpeg_audio_read(
    PhosphorFFmpegAudioDecoder *decoder,
    float *interleaved_samples,
    int maximum_frames,
    double *presentation_time
);

int phosphor_ffmpeg_audio_seek(
    PhosphorFFmpegAudioDecoder *decoder,
    double presentation_time
);

#ifdef __cplusplus
}
#endif

#endif
