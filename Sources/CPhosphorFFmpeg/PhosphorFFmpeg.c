#include "PhosphorFFmpeg.h"

#include <CoreFoundation/CoreFoundation.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct PhosphorFFmpegVideoDecoder {
    AVFormatContext *format;
    AVCodecContext *codec;
    AVBufferRef *hardware_device;
    AVFrame *frame;
    AVPacket *packet;
    struct SwsContext *scaler;
    int stream_index;
    AVRational time_base;
    double frame_rate;
    int64_t fallback_frame_number;
    bool sent_eof;
};

struct PhosphorFFmpegAudioDecoder {
    AVFormatContext *format;
    AVCodecContext *codec;
    AVFrame *frame;
    AVPacket *packet;
    SwrContext *resampler;
    int stream_index;
    AVRational time_base;
    float *pending_samples;
    int pending_capacity;
    int pending_frames;
    int pending_offset;
    double pending_time;
    bool sent_eof;
};

static void write_error(char *buffer, size_t size, const char *message, int error) {
    if (!buffer || size == 0) {
        return;
    }
    if (error < 0) {
        char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(error, detail, sizeof(detail));
        snprintf(buffer, size, "%s: %s", message, detail);
    } else {
        snprintf(buffer, size, "%s", message);
    }
}

static double stream_duration(AVFormatContext *format, AVStream *stream) {
    if (stream->duration != AV_NOPTS_VALUE) {
        return stream->duration * av_q2d(stream->time_base);
    }
    if (format->duration != AV_NOPTS_VALUE) {
        return (double)format->duration / AV_TIME_BASE;
    }
    return 0;
}

static enum AVPixelFormat choose_video_format(
    AVCodecContext *context,
    const enum AVPixelFormat *formats
) {
    (void)context;
    for (const enum AVPixelFormat *format = formats;
         *format != AV_PIX_FMT_NONE;
         ++format) {
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) {
            return *format;
        }
    }
    return formats[0];
}

static bool codec_supports_videotoolbox(const AVCodec *codec) {
    for (int index = 0; ; ++index) {
        const AVCodecHWConfig *configuration = avcodec_get_hw_config(codec, index);
        if (!configuration) {
            return false;
        }
        if (configuration->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX
            && (configuration->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
            return true;
        }
    }
}

static bool hardware_video_is_disabled(void) {
    const char *value = getenv("PHOSPHOR_DISABLE_VIDEOTOOLBOX");
    return value && value[0] != '\0' && strcmp(value, "0") != 0;
}

static AVCodecContext *open_codec(
    AVFormatContext *format,
    int stream_index,
    bool hardware_video,
    AVBufferRef **hardware_device,
    char *error_buffer,
    size_t error_buffer_size
) {
    AVStream *stream = format->streams[stream_index];
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        write_error(error_buffer, error_buffer_size, "No FFmpeg decoder", 0);
        return NULL;
    }

    AVCodecContext *context = avcodec_alloc_context3(codec);
    if (!context) {
        write_error(error_buffer, error_buffer_size, "Unable to allocate decoder", 0);
        return NULL;
    }
    int result = avcodec_parameters_to_context(context, stream->codecpar);
    if (result < 0) {
        write_error(error_buffer, error_buffer_size, "Unable to configure decoder", result);
        avcodec_free_context(&context);
        return NULL;
    }

    if (hardware_video
        && !hardware_video_is_disabled()
        && codec_supports_videotoolbox(codec)) {
        result = av_hwdevice_ctx_create(
            hardware_device,
            AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
            NULL,
            NULL,
            0
        );
        if (result >= 0) {
            context->hw_device_ctx = av_buffer_ref(*hardware_device);
            context->get_format = choose_video_format;
        }
    }

    result = avcodec_open2(context, codec, NULL);
    if (result < 0 && context->hw_device_ctx) {
        avcodec_free_context(&context);
        av_buffer_unref(hardware_device);
        return open_codec(
            format,
            stream_index,
            false,
            hardware_device,
            error_buffer,
            error_buffer_size
        );
    }
    if (result < 0) {
        write_error(error_buffer, error_buffer_size, "Unable to open decoder", result);
        avcodec_free_context(&context);
        return NULL;
    }
    return context;
}

PhosphorFFmpegVideoDecoder *phosphor_ffmpeg_video_open(
    const char *path,
    PhosphorFFmpegMediaInfo *info,
    char *error_buffer,
    size_t error_buffer_size
) {
    if (!path || !info) {
        write_error(error_buffer, error_buffer_size, "Invalid media path", 0);
        return NULL;
    }

    PhosphorFFmpegVideoDecoder *decoder = calloc(1, sizeof(*decoder));
    if (!decoder) {
        write_error(error_buffer, error_buffer_size, "Unable to allocate FFmpeg state", 0);
        return NULL;
    }
    int result = avformat_open_input(&decoder->format, path, NULL, NULL);
    if (result < 0) {
        write_error(error_buffer, error_buffer_size, "Unable to open media", result);
        phosphor_ffmpeg_video_close(decoder);
        return NULL;
    }
    result = avformat_find_stream_info(decoder->format, NULL);
    if (result < 0) {
        write_error(error_buffer, error_buffer_size, "Unable to inspect media", result);
        phosphor_ffmpeg_video_close(decoder);
        return NULL;
    }
    decoder->stream_index = av_find_best_stream(
        decoder->format,
        AVMEDIA_TYPE_VIDEO,
        -1,
        -1,
        NULL,
        0
    );
    if (decoder->stream_index < 0) {
        write_error(error_buffer, error_buffer_size, "Media has no video stream", decoder->stream_index);
        phosphor_ffmpeg_video_close(decoder);
        return NULL;
    }
    decoder->codec = open_codec(
        decoder->format,
        decoder->stream_index,
        true,
        &decoder->hardware_device,
        error_buffer,
        error_buffer_size
    );
    decoder->frame = av_frame_alloc();
    decoder->packet = av_packet_alloc();
    if (!decoder->codec || !decoder->frame || !decoder->packet) {
        if (decoder->codec) {
            write_error(error_buffer, error_buffer_size, "Unable to allocate video frames", 0);
        }
        phosphor_ffmpeg_video_close(decoder);
        return NULL;
    }

    AVStream *stream = decoder->format->streams[decoder->stream_index];
    decoder->time_base = stream->time_base;
    AVRational rate = av_guess_frame_rate(decoder->format, stream, NULL);
    decoder->frame_rate = rate.num > 0 && rate.den > 0 ? av_q2d(rate) : 0;
    enum AVFieldOrder field_order = stream->codecpar->field_order;
    memset(info, 0, sizeof(*info));
    info->duration = stream_duration(decoder->format, stream);
    info->nominal_frame_rate = decoder->frame_rate;
    info->width = decoder->codec->width;
    info->height = decoder->codec->height;
    info->is_interlaced = field_order != AV_FIELD_PROGRESSIVE
        && field_order != AV_FIELD_UNKNOWN;
    info->is_bottom_field_first = field_order == AV_FIELD_BB
        || field_order == AV_FIELD_BT;
    info->is_hdr = stream->codecpar->color_trc == AVCOL_TRC_SMPTE2084
        || stream->codecpar->color_trc == AVCOL_TRC_ARIB_STD_B67;
    info->has_audio = av_find_best_stream(
        decoder->format,
        AVMEDIA_TYPE_AUDIO,
        -1,
        -1,
        NULL,
        0
    ) >= 0;
    return decoder;
}

void phosphor_ffmpeg_video_close(PhosphorFFmpegVideoDecoder *decoder) {
    if (!decoder) {
        return;
    }
    sws_freeContext(decoder->scaler);
    av_packet_free(&decoder->packet);
    av_frame_free(&decoder->frame);
    avcodec_free_context(&decoder->codec);
    av_buffer_unref(&decoder->hardware_device);
    avformat_close_input(&decoder->format);
    free(decoder);
}

static int pump_video_packet(PhosphorFFmpegVideoDecoder *decoder) {
    while (true) {
        int result = av_read_frame(decoder->format, decoder->packet);
        if (result < 0) {
            if (!decoder->sent_eof) {
                decoder->sent_eof = true;
                return avcodec_send_packet(decoder->codec, NULL);
            }
            return AVERROR_EOF;
        }
        if (decoder->packet->stream_index != decoder->stream_index) {
            av_packet_unref(decoder->packet);
            continue;
        }
        result = avcodec_send_packet(decoder->codec, decoder->packet);
        av_packet_unref(decoder->packet);
        return result;
    }
}

static enum AVColorPrimaries effective_color_primaries(
    const AVFrame *frame,
    const AVCodecContext *codec
) {
    return frame->color_primaries != AVCOL_PRI_UNSPECIFIED
        ? frame->color_primaries
        : codec->color_primaries;
}

static enum AVColorTransferCharacteristic effective_color_transfer(
    const AVFrame *frame,
    const AVCodecContext *codec
) {
    return frame->color_trc != AVCOL_TRC_UNSPECIFIED
        ? frame->color_trc
        : codec->color_trc;
}

static enum AVColorSpace effective_color_space(
    const AVFrame *frame,
    const AVCodecContext *codec
) {
    return frame->colorspace != AVCOL_SPC_UNSPECIFIED
        ? frame->colorspace
        : codec->colorspace;
}

static enum AVColorRange effective_color_range(
    const AVFrame *frame,
    const AVCodecContext *codec
) {
    return frame->color_range != AVCOL_RANGE_UNSPECIFIED
        ? frame->color_range
        : codec->color_range;
}

static bool frame_uses_hdr_or_wide_color(
    const AVFrame *frame,
    const AVCodecContext *codec
) {
    enum AVColorTransferCharacteristic transfer = effective_color_transfer(
        frame,
        codec
    );
    return transfer == AVCOL_TRC_SMPTE2084
        || transfer == AVCOL_TRC_ARIB_STD_B67
        || effective_color_primaries(frame, codec) == AVCOL_PRI_BT2020
        || effective_color_primaries(frame, codec) == AVCOL_PRI_SMPTE432;
}

static int swscale_color_space(
    const AVFrame *frame,
    const AVCodecContext *codec
) {
    switch (effective_color_space(frame, codec)) {
        case AVCOL_SPC_BT2020_NCL:
        case AVCOL_SPC_BT2020_CL:
            return SWS_CS_BT2020;
        case AVCOL_SPC_BT709:
            return SWS_CS_ITU709;
        case AVCOL_SPC_FCC:
            return SWS_CS_FCC;
        case AVCOL_SPC_SMPTE240M:
            return SWS_CS_SMPTE240M;
        case AVCOL_SPC_BT470BG:
        case AVCOL_SPC_SMPTE170M:
            return SWS_CS_ITU601;
        default:
            return frame->height > 576 ? SWS_CS_ITU709 : SWS_CS_ITU601;
    }
}

static void attach_frame_color_properties(
    CVPixelBufferRef pixel_buffer,
    const AVFrame *frame,
    const AVCodecContext *codec,
    bool supplies_defaults
) {
    enum AVColorPrimaries color_primaries = effective_color_primaries(
        frame,
        codec
    );
    enum AVColorTransferCharacteristic color_transfer = effective_color_transfer(
        frame,
        codec
    );
    enum AVColorSpace color_space = effective_color_space(frame, codec);
    CFStringRef primaries = kCVImageBufferColorPrimaries_ITU_R_709_2;
    if (color_primaries == AVCOL_PRI_BT2020) {
        primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
    } else if (color_primaries == AVCOL_PRI_SMPTE432) {
        primaries = kCVImageBufferColorPrimaries_P3_D65;
    }

    CFStringRef transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
    if (color_transfer == AVCOL_TRC_SMPTE2084) {
        transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
    } else if (color_transfer == AVCOL_TRC_ARIB_STD_B67) {
        transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG;
    } else if (color_transfer == AVCOL_TRC_LINEAR) {
        transfer = kCVImageBufferTransferFunction_Linear;
    }

    CFStringRef matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    if (color_space == AVCOL_SPC_BT2020_NCL
        || color_space == AVCOL_SPC_BT2020_CL) {
        matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
    } else if (color_space == AVCOL_SPC_BT470BG
        || color_space == AVCOL_SPC_SMPTE170M) {
        matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    }

    if (supplies_defaults || color_primaries != AVCOL_PRI_UNSPECIFIED) {
        CVBufferSetAttachment(
            pixel_buffer,
            kCVImageBufferColorPrimariesKey,
            primaries,
            kCVAttachmentMode_ShouldPropagate
        );
    }
    if (supplies_defaults || color_transfer != AVCOL_TRC_UNSPECIFIED) {
        CVBufferSetAttachment(
            pixel_buffer,
            kCVImageBufferTransferFunctionKey,
            transfer,
            kCVAttachmentMode_ShouldPropagate
        );
    }
    if (supplies_defaults || color_space != AVCOL_SPC_UNSPECIFIED) {
        CVBufferSetAttachment(
            pixel_buffer,
            kCVImageBufferYCbCrMatrixKey,
            matrix,
            kCVAttachmentMode_ShouldPropagate
        );
    }
}

static CVPixelBufferRef make_software_pixel_buffer(
    AVFrame *frame,
    AVCodecContext *codec,
    struct SwsContext **scaler
) {
    bool preserves_hdr = frame_uses_hdr_or_wide_color(frame, codec);
    OSType pixel_format = preserves_hdr
        ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        : kCVPixelFormatType_32BGRA;
    enum AVPixelFormat destination_format = preserves_hdr
        ? AV_PIX_FMT_P010
        : AV_PIX_FMT_BGRA;
    const void *keys[] = {
        kCVPixelBufferMetalCompatibilityKey,
        kCVPixelBufferIOSurfacePropertiesKey
    };
    CFDictionaryRef empty = CFDictionaryCreate(
        kCFAllocatorDefault,
        NULL,
        NULL,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    const void *values[] = { kCFBooleanTrue, empty };
    CFDictionaryRef attributes = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CVPixelBufferRef pixel_buffer = NULL;
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        frame->width,
        frame->height,
        pixel_format,
        attributes,
        &pixel_buffer
    );
    CFRelease(attributes);
    CFRelease(empty);
    if (status != kCVReturnSuccess || !pixel_buffer) {
        return NULL;
    }

    *scaler = sws_getCachedContext(
        *scaler,
        frame->width,
        frame->height,
        (enum AVPixelFormat)frame->format,
        frame->width,
        frame->height,
        destination_format,
        SWS_BILINEAR,
        NULL,
        NULL,
        NULL
    );
    if (!*scaler) {
        CVPixelBufferRelease(pixel_buffer);
        return NULL;
    }

    // swscale does not infer the YUV matrix reliably from AVFrame metadata.
    // Select it explicitly so software-decoded BT.2020/709 frames reach the
    // shader as correctly interpreted, still-transfer-encoded sample values.
    const int *source_coefficients = sws_getCoefficients(
        swscale_color_space(frame, codec)
    );
    const int *destination_coefficients = sws_getCoefficients(SWS_CS_ITU709);
    if (preserves_hdr) {
        destination_coefficients = source_coefficients;
    }
    (void)sws_setColorspaceDetails(
        *scaler,
        source_coefficients,
        effective_color_range(frame, codec) == AVCOL_RANGE_JPEG,
        destination_coefficients,
        preserves_hdr ? 0 : 1,
        0,
        1 << 16,
        1 << 16
    );

    CVPixelBufferLockBaseAddress(pixel_buffer, 0);
    uint8_t *destination[] = {
        preserves_hdr
            ? CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 0)
            : CVPixelBufferGetBaseAddress(pixel_buffer),
        preserves_hdr
            ? CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 1)
            : NULL,
        NULL,
        NULL
    };
    int destination_stride[] = {
        (int)(preserves_hdr
            ? CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 0)
            : CVPixelBufferGetBytesPerRow(pixel_buffer)),
        preserves_hdr
            ? (int)CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 1)
            : 0,
        0,
        0
    };
    int converted = sws_scale(
        *scaler,
        (const uint8_t *const *)frame->data,
        frame->linesize,
        0,
        frame->height,
        destination,
        destination_stride
    );
    CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
    if (converted <= 0) {
        CVPixelBufferRelease(pixel_buffer);
        return NULL;
    }
    attach_frame_color_properties(pixel_buffer, frame, codec, true);
    return pixel_buffer;
}

int phosphor_ffmpeg_video_read(
    PhosphorFFmpegVideoDecoder *decoder,
    CVPixelBufferRef *pixel_buffer,
    double *presentation_time
) {
    if (!decoder || !pixel_buffer || !presentation_time) {
        return -1;
    }
    *pixel_buffer = NULL;

    while (true) {
        int result = avcodec_receive_frame(decoder->codec, decoder->frame);
        if (result == 0) {
            CVPixelBufferRef output = NULL;
            if (decoder->frame->format == AV_PIX_FMT_VIDEOTOOLBOX
                && decoder->frame->data[3]) {
                output = (CVPixelBufferRef)decoder->frame->data[3];
                CVPixelBufferRetain(output);
                attach_frame_color_properties(
                    output,
                    decoder->frame,
                    decoder->codec,
                    false
                );
            } else {
                output = make_software_pixel_buffer(
                    decoder->frame,
                    decoder->codec,
                    &decoder->scaler
                );
            }
            int64_t timestamp = decoder->frame->best_effort_timestamp;
            if (timestamp != AV_NOPTS_VALUE) {
                *presentation_time = timestamp * av_q2d(decoder->time_base);
            } else if (decoder->frame_rate > 0) {
                *presentation_time = decoder->fallback_frame_number / decoder->frame_rate;
            } else {
                *presentation_time = 0;
            }
            decoder->fallback_frame_number += 1;
            av_frame_unref(decoder->frame);
            if (!output) {
                return -1;
            }
            *pixel_buffer = output;
            return 1;
        }
        if (result == AVERROR_EOF) {
            return 0;
        }
        if (result != AVERROR(EAGAIN)) {
            return -1;
        }
        result = pump_video_packet(decoder);
        if (result < 0 && result != AVERROR(EAGAIN) && result != AVERROR_EOF) {
            return -1;
        }
    }
}

int phosphor_ffmpeg_video_seek(
    PhosphorFFmpegVideoDecoder *decoder,
    double presentation_time
) {
    if (!decoder || !isfinite(presentation_time)) {
        return -1;
    }
    int64_t timestamp = (int64_t)(fmax(presentation_time, 0) / av_q2d(decoder->time_base));
    int result = avformat_seek_file(
        decoder->format,
        decoder->stream_index,
        INT64_MIN,
        timestamp,
        timestamp,
        AVSEEK_FLAG_BACKWARD
    );
    if (result < 0) {
        return result;
    }
    avcodec_flush_buffers(decoder->codec);
    decoder->sent_eof = false;
    decoder->fallback_frame_number = (int64_t)(presentation_time * decoder->frame_rate);
    return 0;
}

PhosphorFFmpegAudioDecoder *phosphor_ffmpeg_audio_open(
    const char *path,
    char *error_buffer,
    size_t error_buffer_size
) {
    PhosphorFFmpegAudioDecoder *decoder = calloc(1, sizeof(*decoder));
    if (!decoder) {
        return NULL;
    }
    int result = avformat_open_input(&decoder->format, path, NULL, NULL);
    if (result < 0 || avformat_find_stream_info(decoder->format, NULL) < 0) {
        write_error(error_buffer, error_buffer_size, "Unable to open audio", result);
        phosphor_ffmpeg_audio_close(decoder);
        return NULL;
    }
    decoder->stream_index = av_find_best_stream(
        decoder->format,
        AVMEDIA_TYPE_AUDIO,
        -1,
        -1,
        NULL,
        0
    );
    if (decoder->stream_index < 0) {
        write_error(error_buffer, error_buffer_size, "Media has no audio stream", 0);
        phosphor_ffmpeg_audio_close(decoder);
        return NULL;
    }
    decoder->codec = open_codec(
        decoder->format,
        decoder->stream_index,
        false,
        NULL,
        error_buffer,
        error_buffer_size
    );
    decoder->frame = av_frame_alloc();
    decoder->packet = av_packet_alloc();
    if (!decoder->codec || !decoder->frame || !decoder->packet) {
        phosphor_ffmpeg_audio_close(decoder);
        return NULL;
    }

    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    result = swr_alloc_set_opts2(
        &decoder->resampler,
        &stereo,
        AV_SAMPLE_FMT_FLT,
        48000,
        &decoder->codec->ch_layout,
        decoder->codec->sample_fmt,
        decoder->codec->sample_rate,
        0,
        NULL
    );
    if (result < 0 || !decoder->resampler || swr_init(decoder->resampler) < 0) {
        write_error(error_buffer, error_buffer_size, "Unable to configure audio", result);
        phosphor_ffmpeg_audio_close(decoder);
        return NULL;
    }
    decoder->time_base = decoder->format->streams[decoder->stream_index]->time_base;
    return decoder;
}

void phosphor_ffmpeg_audio_close(PhosphorFFmpegAudioDecoder *decoder) {
    if (!decoder) {
        return;
    }
    free(decoder->pending_samples);
    swr_free(&decoder->resampler);
    av_packet_free(&decoder->packet);
    av_frame_free(&decoder->frame);
    avcodec_free_context(&decoder->codec);
    avformat_close_input(&decoder->format);
    free(decoder);
}

static int pump_audio_packet(PhosphorFFmpegAudioDecoder *decoder) {
    while (true) {
        int result = av_read_frame(decoder->format, decoder->packet);
        if (result < 0) {
            if (!decoder->sent_eof) {
                decoder->sent_eof = true;
                return avcodec_send_packet(decoder->codec, NULL);
            }
            return AVERROR_EOF;
        }
        if (decoder->packet->stream_index != decoder->stream_index) {
            av_packet_unref(decoder->packet);
            continue;
        }
        result = avcodec_send_packet(decoder->codec, decoder->packet);
        av_packet_unref(decoder->packet);
        return result;
    }
}

static int fill_pending_audio(PhosphorFFmpegAudioDecoder *decoder) {
    while (true) {
        int result = avcodec_receive_frame(decoder->codec, decoder->frame);
        if (result == 0) {
            int output_frames = swr_get_out_samples(
                decoder->resampler,
                decoder->frame->nb_samples
            );
            if (output_frames <= 0) {
                av_frame_unref(decoder->frame);
                continue;
            }
            if (output_frames > decoder->pending_capacity) {
                float *resized = realloc(
                    decoder->pending_samples,
                    (size_t)output_frames * 2 * sizeof(float)
                );
                if (!resized) {
                    av_frame_unref(decoder->frame);
                    return -1;
                }
                decoder->pending_samples = resized;
                decoder->pending_capacity = output_frames;
            }
            uint8_t *output[] = { (uint8_t *)decoder->pending_samples };
            int converted = swr_convert(
                decoder->resampler,
                output,
                output_frames,
                (const uint8_t **)decoder->frame->extended_data,
                decoder->frame->nb_samples
            );
            int64_t timestamp = decoder->frame->best_effort_timestamp;
            decoder->pending_time = timestamp == AV_NOPTS_VALUE
                ? 0
                : timestamp * av_q2d(decoder->time_base);
            decoder->pending_frames = converted;
            decoder->pending_offset = 0;
            av_frame_unref(decoder->frame);
            return converted > 0 ? 1 : -1;
        }
        if (result == AVERROR_EOF) {
            return 0;
        }
        if (result != AVERROR(EAGAIN)) {
            return -1;
        }
        result = pump_audio_packet(decoder);
        if (result < 0 && result != AVERROR(EAGAIN) && result != AVERROR_EOF) {
            return -1;
        }
    }
}

int phosphor_ffmpeg_audio_read(
    PhosphorFFmpegAudioDecoder *decoder,
    float *interleaved_samples,
    int maximum_frames,
    double *presentation_time
) {
    if (!decoder || !interleaved_samples || maximum_frames <= 0 || !presentation_time) {
        return -1;
    }
    if (decoder->pending_offset >= decoder->pending_frames) {
        int status = fill_pending_audio(decoder);
        if (status <= 0) {
            return status;
        }
    }
    int available = decoder->pending_frames - decoder->pending_offset;
    int count = available < maximum_frames ? available : maximum_frames;
    memcpy(
        interleaved_samples,
        decoder->pending_samples + decoder->pending_offset * 2,
        (size_t)count * 2 * sizeof(float)
    );
    *presentation_time = decoder->pending_time
        + (double)decoder->pending_offset / 48000.0;
    decoder->pending_offset += count;
    return count;
}

int phosphor_ffmpeg_audio_seek(
    PhosphorFFmpegAudioDecoder *decoder,
    double presentation_time
) {
    if (!decoder || !isfinite(presentation_time)) {
        return -1;
    }
    int64_t timestamp = (int64_t)(fmax(presentation_time, 0) / av_q2d(decoder->time_base));
    int result = avformat_seek_file(
        decoder->format,
        decoder->stream_index,
        INT64_MIN,
        timestamp,
        timestamp,
        AVSEEK_FLAG_BACKWARD
    );
    if (result < 0) {
        return result;
    }
    avcodec_flush_buffers(decoder->codec);
    swr_close(decoder->resampler);
    swr_init(decoder->resampler);
    decoder->pending_frames = 0;
    decoder->pending_offset = 0;
    decoder->sent_eof = false;
    return 0;
}
