/*
 * Headless smoke test for the Breeze C ABI.
 *
 *   clang -O2 -I Vendor/include tools/engine_smoke.c \
 *         -L Vendor -lbreeze -Wl,-rpath,@executable_path/../Vendor \
 *         -o build-static/engine_smoke
 *   ./build-static/engine_smoke <model.gguf> <out.wav> "<text>"
 *
 * Prints the sample rate, chunk count, audio duration and wall time so the same
 * numbers can be compared with what the app reports.
 */
#include "breeze/breeze.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static long g_samples = 0;
static int g_chunks = 0;
static double g_first_chunk_at = 0.0;
static double g_start = 0.0;

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec + (double) ts.tv_nsec / 1e9;
}

static int on_audio(const float *samples, int n, void *user) {
    (void) samples;
    (void) user;
    if (g_chunks == 0) {
        g_first_chunk_at = now_seconds() - g_start;
    }
    g_chunks++;
    g_samples += n;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <model.gguf> <out.wav> <text> [use_gpu]\n", argv[0]);
        return 2;
    }

    const char *model = argv[1];
    const char *out = argv[2];
    const char *text = argv[3];
    int use_gpu = (argc > 4) ? atoi(argv[4]) : 1;

    g_start = now_seconds();
    breeze_context *ctx = breeze_init(model, use_gpu);
    double load_done = now_seconds() - g_start;
    if (!ctx) {
        fprintf(stderr, "breeze_init failed: %s\n", breeze_last_error());
        return 1;
    }

    int rate = breeze_sample_rate(ctx);
    printf("sample_rate: %d\n", rate);
    printf("load_seconds: %.2f\n", load_done);

    breeze_request req;
    memset(&req, 0, sizeof(req));
    req.text = text;
    req.instruction = "Speak clearly and naturally.";
    req.cfg_scale = 1.0f;
    req.seed = 42;
    req.max_new_tokens = 0;
    req.split_chars = 0;

    double gen_start = now_seconds();
    int rc = breeze_generate(ctx, &req, on_audio, NULL);
    double gen_done = now_seconds() - gen_start;

    if (rc != 0) {
        fprintf(stderr, "breeze_generate failed: %s\n", breeze_last_error());
        breeze_free(ctx);
        return 1;
    }

    printf("chunks: %d\n", g_chunks);
    printf("samples: %ld\n", g_samples);
    printf("audio_seconds: %.2f\n", rate > 0 ? (double) g_samples / rate : 0.0);
    printf("first_chunk_seconds: %.2f\n", g_first_chunk_at);
    printf("generate_seconds: %.2f\n", gen_done);

    double wav_start = now_seconds();
    rc = breeze_generate_wav(ctx, &req, out);
    printf("wav_seconds: %.2f\n", now_seconds() - wav_start);
    if (rc != 0) {
        fprintf(stderr, "breeze_generate_wav failed: %s\n", breeze_last_error());
        breeze_free(ctx);
        return 1;
    }

    printf("wav: %s\n", out);
    breeze_free(ctx);
    return 0;
}
