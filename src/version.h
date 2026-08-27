#pragma once
#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

namespace yap {

namespace detail {

// Splits a version into its leading dotted-numeric components and whatever text
// follows them. A leading 'v' is dropped, so a GitHub tag ("v0.4.0") parses the
// same as CFBundleShortVersionString ("0.4.0").
inline void version_parse(const std::string & s,
                          std::vector<long> & parts, std::string & suffix) {
    size_t i = 0;
    if (i < s.size() && (s[i] == 'v' || s[i] == 'V')) ++i;
    while (i < s.size() && std::isdigit((unsigned char) s[i])) {
        long n = 0;
        while (i < s.size() && std::isdigit((unsigned char) s[i])) {
            // Clamp rather than overflow. A tag long enough to wrap a long is not
            // a version, and signed overflow is undefined -- the comparison must
            // stay total whatever garbage the network hands us.
            if (n < 100000000L) n = n * 10 + (s[i] - '0');
            ++i;
        }
        parts.push_back(n);
        if (i < s.size() && s[i] == '.') { ++i; continue; }
        break;
    }
    suffix = s.substr(i);
}

}  // namespace detail

// Compares two versions: <0 if a is older than b, 0 if equal, >0 if newer.
// Missing components read as zero, so "0.4" == "0.4.0".
//
// Comparing version strings lexically is the bug this exists to prevent: "0.10.0"
// sorts BEFORE "0.9.0", so the tenth release of any component would be invisible
// to every copy already installed -- and by then it cannot be fixed by shipping
// a fix, because no one would be offered it.
inline int version_compare(const std::string & a, const std::string & b) {
    std::vector<long> pa, pb;
    std::string sa, sb;
    detail::version_parse(a, pa, sa);
    detail::version_parse(b, pb, sb);

    const size_t n = std::max(pa.size(), pb.size());
    for (size_t i = 0; i < n; ++i) {
        const long x = i < pa.size() ? pa[i] : 0;
        const long y = i < pb.size() ? pb[i] : 0;
        if (x != y) return x < y ? -1 : 1;
    }

    // Semver's pre-release rule: 1.0.0-rc1 precedes 1.0.0. Only the presence of a
    // suffix is modelled; suffix against suffix falls back to a lexical compare,
    // which gets rc9 vs. rc10 wrong. The app only ever reads /releases/latest,
    // which excludes pre-releases, so this is a tiebreak for hand-made tags
    // rather than a path anything depends on.
    if (sa.empty() != sb.empty()) return sa.empty() ? 1 : -1;
    if (sa != sb)                 return sa < sb ? -1 : 1;
    return 0;
}

}  // namespace yap
