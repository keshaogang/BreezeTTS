#import "BreezeBridge.h"

#include "breeze/breeze.h"

#include <cstring>
#include <string>

/// Context handed to the C callback. `block` is borrowed: the caller keeps it
/// alive for the whole `breeze_generate` call.
struct BreezeCallbackContext {
    __unsafe_unretained BreezeChunkBlock block;
    bool stopped;
};

static int BreezeAudioThunk(const float *samples, int count, void *user) {
    BreezeCallbackContext *ctx = static_cast<BreezeCallbackContext *>(user);
    if (ctx == nullptr || ctx->block == nil) return 0;
    if (ctx->stopped) return 1;

    @autoreleasepool {
        // The buffer is only valid inside this call, so copy it out immediately.
        NSData *payload = [NSData dataWithBytes:samples
                                         length:(NSUInteger)count * sizeof(float)];
        BOOL stop = NO;
        ctx->block(payload, &stop);
        if (stop) {
            ctx->stopped = true;
            return 1;
        }
    }
    return 0;
}

@interface BreezeEngine () {
    breeze_context *_ctx;
    NSInteger _sampleRate;
    NSLock *_lock;
    BOOL _busy;
}
@end

@implementation BreezeEngine

- (nullable instancetype)initWithModelPath:(NSString *)path useGPU:(BOOL)useGPU {
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return nil;
    }

    breeze_context *ctx = breeze_init(path.UTF8String, useGPU ? 1 : 0);
    if (ctx == nullptr) {
        return nil;
    }

    self = [super init];
    if (self == nil) {
        breeze_free(ctx);
        return nil;
    }
    _ctx = ctx;
    _sampleRate = breeze_sample_rate(ctx);
    _lock = [[NSLock alloc] init];
    _busy = NO;
    return self;
}

- (NSInteger)sampleRate {
    return _sampleRate > 0 ? _sampleRate : 24000;
}

- (NSString *)backendName {
    if (_ctx == nullptr) return @"";
    const char *name = breeze_backend_name(_ctx);
    if (!name) return @"";
    NSString *raw = [NSString stringWithUTF8String:name];
    // ggml reports the per-device name ("MTL0", "CPU", ...); the UI wants the
    // backend family so a fallback reads as "CPU 加速" and GPU as "Metal 加速".
    if ([raw hasPrefix:@"MTL"]) return @"Metal";
    return raw;
}

- (BOOL)busy {
    return _busy;
}

- (void)shutdown {
    [_lock lock];
    if (_ctx != nullptr) {
        breeze_free(_ctx);
        _ctx = nullptr;
    }
    [_lock unlock];
}

- (void)dealloc {
    if (_ctx != nullptr) {
        breeze_free(_ctx);
        _ctx = nullptr;
    }
}

/// Fills a zeroed request. Strings are kept alive by the caller's locals.
static void BreezeFillRequest(breeze_request *req,
                              NSString *text,
                              NSString *instruction,
                              NSString *refText,
                              const float *refAudio,
                              int refAudioLen,
                              float cfgScale,
                              NSInteger seed,
                              NSInteger maxNewTokens,
                              NSInteger splitChars,
                              float temperature,
                              NSInteger topK,
                              float topP,
                              float repetitionPenalty,
                              NSInteger chunkFirst,
                              NSInteger chunkMax) {
    memset(req, 0, sizeof(*req));
    req->text = text.UTF8String;
    req->instruction = instruction.length > 0 ? instruction.UTF8String : NULL;
    req->ref_text = refText.length > 0 ? refText.UTF8String : NULL;
    req->ref_audio = refAudio;
    req->ref_audio_len = refAudioLen;
    req->cfg_scale = cfgScale;
    req->seed = (int)seed;
    req->max_new_tokens = (int)maxNewTokens;
    req->split_chars = (int)splitChars;
    req->temperature = temperature;
    req->top_k = (int)topK;
    req->top_p = topP;
    req->repetition_penalty = repetitionPenalty;
    req->chunk_first = (int)chunkFirst;
    req->chunk_max = (int)chunkMax;
}

- (BOOL)generateWithText:(NSString *)text
             instruction:(nullable NSString *)instruction
                 refText:(nullable NSString *)refText
         refAudioSamples:(nullable NSData *)refAudioSamples
                cfgScale:(float)cfgScale
                    seed:(NSInteger)seed
            maxNewTokens:(NSInteger)maxNewTokens
              splitChars:(NSInteger)splitChars
                temperature:(float)temperature
                       topK:(NSInteger)topK
                       topP:(float)topP
          repetitionPenalty:(float)repetitionPenalty
                 chunkFirst:(NSInteger)chunkFirst
                   chunkMax:(NSInteger)chunkMax
                    onChunk:(nullable BreezeChunkBlock)onChunk {
    if (text.length == 0) {
        return NO;
    }
    if (refAudioSamples.length > 0 && refText.length == 0) {
        return NO;
    }
    if (_ctx == nullptr) {
        return NO;
    }

    [_lock lock];
    _busy = YES;
    BOOL ok = NO;
    @try {
        // Keep every string alive for the duration of the C call.
        NSString *textCopy = [text copy];
        NSString *instructionCopy = [instruction copy];
        NSString *refTextCopy = [refText copy];
        const float *refPtr = NULL;
        int refLen = 0;
        if (refAudioSamples.length >= sizeof(float)) {
            refPtr = static_cast<const float *>(refAudioSamples.bytes);
            refLen = (int)(refAudioSamples.length / sizeof(float));
        }

        breeze_request req;
        BreezeFillRequest(&req, textCopy, instructionCopy, refTextCopy, refPtr, refLen,
                          cfgScale, seed, maxNewTokens, splitChars,
                          temperature, topK, topP, repetitionPenalty,
                          chunkFirst, chunkMax);

        BreezeCallbackContext ctx;
        ctx.block = onChunk;
        ctx.stopped = false;

        int rc = breeze_generate(_ctx, &req, onChunk ? BreezeAudioThunk : NULL, &ctx);
        ok = (rc == 0);
    } @finally {
        _busy = NO;
        [_lock unlock];
    }
    return ok;
}

- (BOOL)generateWAVWithText:(NSString *)text
                instruction:(nullable NSString *)instruction
                    refText:(nullable NSString *)refText
            refAudioSamples:(nullable NSData *)refAudioSamples
                   cfgScale:(float)cfgScale
                       seed:(NSInteger)seed
               maxNewTokens:(NSInteger)maxNewTokens
                 splitChars:(NSInteger)splitChars
                temperature:(float)temperature
                       topK:(NSInteger)topK
                       topP:(float)topP
          repetitionPenalty:(float)repetitionPenalty
                    outPath:(NSString *)outPath {
    if (_ctx == nullptr) {
        return NO;
    }
    if (refAudioSamples.length > 0 && refText.length == 0) {
        return NO;
    }

    [_lock lock];
    _busy = YES;
    BOOL ok = NO;
    @try {
        NSString *textCopy = [text copy];
        NSString *instructionCopy = [instruction copy];
        NSString *refTextCopy = [refText copy];
        NSString *outCopy = [outPath copy];
        const float *refPtr = NULL;
        int refLen = 0;
        if (refAudioSamples.length >= sizeof(float)) {
            refPtr = static_cast<const float *>(refAudioSamples.bytes);
            refLen = (int)(refAudioSamples.length / sizeof(float));
        }

        breeze_request req;
        BreezeFillRequest(&req, textCopy, instructionCopy, refTextCopy, refPtr, refLen,
                          cfgScale, seed, maxNewTokens, splitChars,
                          temperature, topK, topP, repetitionPenalty, 0, 0);

        int rc = breeze_generate_wav(_ctx, &req, outCopy.UTF8String);
        ok = (rc == 0);
    } @finally {
        _busy = NO;
        [_lock unlock];
    }
    return ok;
}

+ (NSString *)lastErrorMessage {
    const char *msg = breeze_last_error();
    return msg ? [NSString stringWithUTF8String:msg] : @"";
}

@end
