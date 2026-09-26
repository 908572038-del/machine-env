// probe_hw.cpp — hardware probe emitting JSON on stdout.
//
// Why C++: CPUID is the only trustworthy source for ISA capabilities.
// Win32_Processor.Flags is truncated and misreports AVX2 (verified on this
// machine: WMI said "no AVX2" while CPUID says otherwise), so we probe directly.
//
// Build: see build.ps1
// Usage: probe_hw.exe  ->  single-line JSON object on stdout

#include <cstdio>
#include <cstring>
#include <intrin.h>

static void cpuid(unsigned leaf, unsigned sub, unsigned& a, unsigned& b,
                  unsigned& c, unsigned& d) {
    int ra[4];
    __cpuidex(ra, leaf, sub);
    a = static_cast<unsigned>(ra[0]);
    b = static_cast<unsigned>(ra[1]);
    c = static_cast<unsigned>(ra[2]);
    d = static_cast<unsigned>(ra[3]);
}

static void xgetbv(unsigned reg, unsigned long long& val) {
    val = _xgetbv(reg);
}

// Minimal JSON string escaping (brand strings can contain stray bytes).
static void json_str(const char* s, char* out, size_t cap) {
    size_t j = 0;
    for (size_t i = 0; s[i] && j + 7 < cap; ++i) {
        unsigned char ch = static_cast<unsigned char>(s[i]);
        if (ch == '"' || ch == '\\') {
            out[j++] = '\\';
            out[j++] = static_cast<char>(ch);
        } else if (ch < 0x20 || ch >= 0x7f) {
            j += static_cast<size_t>(snprintf(out + j, cap - j, "\\u%04x", ch));
        } else {
            out[j++] = static_cast<char>(ch);
        }
    }
    out[j] = 0;
}

int main() {
    unsigned a = 0, b = 0, c = 0, d = 0;

    cpuid(0, 0, a, b, c, d);
    unsigned max_leaf = a;

    char vendor[13] = {0};
    memcpy(vendor + 0, &b, 4);
    memcpy(vendor + 4, &d, 4);
    memcpy(vendor + 8, &c, 4);

    // Brand string lives in leaves 0x80000002..0x80000004.
    cpuid(0x80000000u, 0, a, b, c, d);
    unsigned max_ext = a;

    char brand[49] = {0};
    if (max_ext >= 0x80000004u) {
        for (unsigned i = 0; i < 3; ++i) {
            cpuid(0x80000002u + i, 0, a, b, c, d);
            memcpy(brand + i * 16 + 0, &a, 4);
            memcpy(brand + i * 16 + 4, &b, 4);
            memcpy(brand + i * 16 + 8, &c, 4);
            memcpy(brand + i * 16 + 12, &d, 4);
        }
    }
    // Trim leading spaces the firmware often pads with.
    char* brand_trim = brand;
    while (*brand_trim == ' ') ++brand_trim;

    cpuid(1, 0, a, b, c, d);
    const unsigned f1_ecx = c;
    const unsigned stepping = a & 0xF;
    const unsigned model = ((a >> 4) & 0xF) | (((a >> 16) & 0xF) << 4);
    const unsigned family = ((a >> 8) & 0xF) + ((a >> 20) & 0xF);

    // OSXSAVE + XGETBV gate: without OS support the YMM/ZMM state is not
    // preserved across context switches, so AVX* is unusable even if the CPU
    // reports it. Both checks are required.
    const bool osxsave = (f1_ecx & (1u << 27)) != 0;
    const bool avx_cpu = (f1_ecx & (1u << 28)) != 0;
    unsigned long long xcr0 = 0;
    if (osxsave) xgetbv(0, xcr0);
    const bool ymm_ok = (xcr0 & 0x6) == 0x6;   // XMM + YMM state enabled
    const bool zmm_ok = (xcr0 & 0xE6) == 0xE6; // + opmask, ZMM_Hi256, Hi16_ZMM

    cpuid(7, 0, a, b, c, d);
    const unsigned f7_ebx = b;
    const unsigned f7_ecx = c;

    const bool sse42 = (f1_ecx & (1u << 20)) != 0;
    const bool avx = avx_cpu && ymm_ok;
    const bool avx2 = avx && ((f7_ebx & (1u << 5)) != 0);
    const bool fma = avx && ((f1_ecx & (1u << 12)) != 0);
    const bool f16c = avx && ((f1_ecx & (1u << 29)) != 0);
    const bool avx512f = avx && zmm_ok && ((f7_ebx & (1u << 16)) != 0);
    const bool avx512vnni = avx512f && ((f7_ecx & (1u << 11)) != 0);
    const bool avx512bw = avx512f && ((f7_ebx & (1u << 30)) != 0);

    // AVX-VNNI (leaf 7 subleaf 1) — the 256-bit VNNI that works without AVX-512.
    bool avx_vnni = false;
    if (max_leaf >= 7) {
        unsigned a1, b1, c1, d1;
        cpuid(7, 1, a1, b1, c1, d1);
        avx_vnni = (a1 & (1u << 4)) != 0;
    }

    const bool popcnt = (f1_ecx & (1u << 23)) != 0;
    const bool ssse3 = (f1_ecx & (1u << 9)) != 0;
    const bool bmi2 = (f7_ebx & (1u << 8)) != 0;

    char vendor_esc[64], brand_esc[128];
    json_str(vendor, vendor_esc, sizeof(vendor_esc));
    json_str(brand_trim, brand_esc, sizeof(brand_esc));

    printf("{");
    printf("\"vendor\":\"%s\",", vendor_esc);
    printf("\"brand\":\"%s\",", brand_esc);
    printf("\"family\":%u,\"model\":%u,\"stepping\":%u,", family, model, stepping);
    printf("\"max_leaf\":%u,\"max_ext_leaf\":%u,", max_leaf, max_ext);
    printf("\"xcr0\":%llu,", static_cast<unsigned long long>(xcr0));
    printf("\"osxsave\":%s,", osxsave ? "true" : "false");

    // ISA table. Names match the ones used in the project's environment notes
    // so downstream consumers can compare against recorded values directly.
    printf("\"isa\":{");
    printf("\"sse4_2\":%s,", sse42 ? "true" : "false");
    printf("\"ssse3\":%s,", ssse3 ? "true" : "false");
    printf("\"popcnt\":%s,", popcnt ? "true" : "false");
    printf("\"avx\":%s,", avx ? "true" : "false");
    printf("\"avx2\":%s,", avx2 ? "true" : "false");
    printf("\"fma\":%s,", fma ? "true" : "false");
    printf("\"f16c\":%s,", f16c ? "true" : "false");
    printf("\"avx_vnni\":%s,", avx_vnni ? "true" : "false");
    printf("\"avx512f\":%s,", avx512f ? "true" : "false");
    printf("\"avx512bw\":%s,", avx512bw ? "true" : "false");
    printf("\"avx512vnni\":%s,", avx512vnni ? "true" : "false");
    printf("\"bmi2\":%s", bmi2 ? "true" : "false");
    printf("}");

    // Vector width actually usable, which is what kernel selection cares about.
    const char* width = avx512f ? "512" : (avx2 ? "256" : "128");
    printf(",\"vector_width_bits\":%s", width);
    printf("}\n");
    return 0;
}
