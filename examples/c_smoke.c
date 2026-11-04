/*
 * c_smoke.c — a C host for Celeris, built against include/celeris.h and linked
 * against the shared library. Part of `zig build test`: it fails the build if the
 * header stops compiling, drifts from the exported symbols, or the string-keyed
 * property surface stops behaving. Headless — no window, no GPU required.
 */
#include <stdio.h>
#include <string.h>
#include "celeris.h"

static int failures = 0;

#define CHECK(cond)                                                            \
    do {                                                                       \
        if (!(cond)) {                                                         \
            fprintf(stderr, "c_smoke: FAILED %s (line %d): %s\n", #cond,       \
                    __LINE__, celeris_last_error());                           \
            failures++;                                                        \
        }                                                                      \
    } while (0)

int main(void) {
    CHECK(celeris_abi_version() == CELERIS_ABI_VERSION);
    celeris_set_verbose_logging(false);

    CelerisConfig config;
    memset(&config, 0, sizeof config);
    config.is_headless = true;
    int32_t engine = celeris_create_engine(&config);
    if (engine <= 0) {
        /* No usable font on this machine; nothing else can be exercised. */
        fprintf(stderr, "c_smoke: skipped (engine init failed: %s)\n", celeris_last_error());
        return 0;
    }

    uint32_t root = (uint32_t)celeris_node_create(engine, 0);
    uint32_t label = (uint32_t)celeris_node_create(engine, 1);
    CHECK(celeris_node_append_child(engine, root, label) == 0);
    CHECK(celeris_node_set_text_content(engine, label, "Hello from C") == 0);

    CHECK(celeris_node_add_style(engine, root, "background", "#1e1e1e") == 0);
    CHECK(celeris_node_add_style(engine, label, "font-size", "18px") == 0);
    CHECK(celeris_node_add_layout(engine, root, "flex-direction", "column") == 0);
    CHECK(celeris_node_add_layout(engine, root, "width", "100%") == 0);
    CHECK(celeris_node_add_modifier(engine, root, "clickable", "root") == 0);
    CHECK(celeris_node_add_style(engine, root, "no-such-key", "1") == -1);
    CHECK(celeris_node_add_style(engine, root, "background", "chartreuse-ish") == -1);

    int32_t sig = celeris_signal_create(engine);
    CHECK(sig >= 0);
    CHECK(celeris_signal_set_f32(engine, sig, 0.5f) == 0);
    CHECK(celeris_signal_bind_style(engine, sig, root, "opacity") == 0);
    CHECK(celeris_signal_get_f32(engine, sig) == 0.5f);

    CHECK(celeris_animate_style(engine, root, "opacity", 0.0f, 1.0f, 200.0f, 2) == 0);
    CHECK(celeris_cancel_animations(engine, root) == 0);

    const char *dom = celeris_get_dom_json(engine);
    CHECK(dom != NULL && strstr(dom, "\"type\"") != NULL);
    celeris_free_string(engine, dom);

    celeris_deinit(engine);

    if (failures) {
        fprintf(stderr, "c_smoke: %d check(s) failed\n", failures);
        return 1;
    }
    printf("c_smoke: ok\n");
    return 0;
}
