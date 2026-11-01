#include "breeze/breeze.h"
#include "breeze/audio.h"
#include "breeze/generation.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
#include <vector>

using namespace breeze;

struct breeze_context {
    BreezeModel model;
    MimiCodec codec;
};

static std::string g_error;

static GenRequest to_req(const breeze_request * r) {
    GenRequest g;
    g.text = r->text ? r->text : "";
    g.instruction = r->instruction ? r->instruction : "Speak clearly and naturally.";
    g.ref_text = r->ref_text ? r->ref_text : "";
    if (r->ref_audio && r->ref_audio_len > 0)
        g.ref_audio.assign(r->ref_audio, r->ref_audio + r->ref_audio_len);
    g.cfg_scale = r->cfg_scale > 0 ? r->cfg_scale : 1.0f;
    g.seed = r->seed;
    g.max_new_tokens = r->max_new_tokens;
    if (r->split_chars != 0) g.split_chars = r->split_chars < 0 ? 0 : r->split_chars;
    if (r->chunk_first > 0) g.chunk_first = r->chunk_first;
    if (r->chunk_max > 0) g.chunk_max = r->chunk_max;
    g.temperature = r->temperature;
    g.top_k = r->top_k;
    g.top_p = r->top_p;
    g.repetition_penalty = r->repetition_penalty;
    return g;
}

breeze_context * breeze_init(const char * gguf_path, int use_gpu) {
    breeze_context * c = new breeze_context();
    try {
        if (!c->model.load(gguf_path, use_gpu != 0)) {
            g_error = "failed to load model";
            delete c;
            return nullptr;
        }
    } catch (const std::exception & e) {
        g_error = e.what();
        delete c;
        return nullptr;
    }
    c->codec.init(c->model);
    return c;
}

void breeze_free(breeze_context * ctx) {
    if (ctx) {
        ctx->codec.free_backend();
        ctx->model.free();
        delete ctx;
    }
}

int breeze_sample_rate(breeze_context * ctx) {
    return ctx ? ctx->model.cfg.sample_rate : 0;
}

const char * breeze_backend_name(breeze_context * ctx) {
    if (!ctx) return "";
    return ctx->model.backend.name();
}

int breeze_generate(breeze_context * ctx, const breeze_request * req, breeze_audio_cb cb, void * user) {
    try {
        GenRequest g = to_req(req);
        GenTimings tm;
        generate(ctx->model, ctx->codec, g, [&](const float * s, int n) {
            return cb ? cb(s, n, user) == 0 : true;
        }, &tm);
        // BREEZE_TIMINGS=1 keeps a per-stage breakdown on stderr so a slow run can
        // be attributed to the backbone, the depth decoder or the vocoder.
        if (std::getenv("BREEZE_TIMINGS") != nullptr) {
            const int frames = tm.frames > 0 ? tm.frames : 1;
            std::fprintf(stderr,
                         "[timings] prompt=%.0f prefill=%.0f backbone=%.0f depth=%.0f "
                         "vocoder=%.0f frames=%d flushes=%d first_audio=%.2f "
                         "ms_per_frame=%.2f backbone_share=%.0f%%\n",
                         tm.prompt, tm.prefill, tm.backbone, tm.depth, tm.vocoder,
                         tm.frames, tm.flushes, tm.first_audio,
                         (tm.backbone + tm.depth) / frames,
                         100.0 * tm.backbone / std::max(1e-6, tm.backbone + tm.depth));
        }
    } catch (const std::exception & e) {
        g_error = e.what();
        return 1;
    }
    return 0;
}

int breeze_generate_wav(breeze_context * ctx, const breeze_request * req, const char * out_path) {
    try {
        GenRequest g = to_req(req);
        g.pace = false;
        std::vector<float> audio;
        generate(ctx->model, ctx->codec, g, [&](const float * s, int n) {
            audio.insert(audio.end(), s, s + n);
            return true;
        });
        if (!write_wav(out_path, audio, ctx->model.cfg.sample_rate)) {
            g_error = "failed to write wav";
            return 1;
        }
    } catch (const std::exception & e) {
        g_error = e.what();
        return 1;
    }
    return 0;
}

const char * breeze_last_error(void) {
    return g_error.c_str();
}
