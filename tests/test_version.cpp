#include "version.h"
#include <cstdio>

using yap::version_compare;
static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); ++failures; } } while (0)

// Reads at the call site as "a is newer than b".
#define NEWER(a, b) do { CHECK(version_compare(a, b) > 0); CHECK(version_compare(b, a) < 0); } while (0)
#define SAME(a, b)  do { CHECK(version_compare(a, b) == 0); CHECK(version_compare(b, a) == 0); } while (0)

int main() {
    SAME("0.3.1", "0.3.1");
    NEWER("0.3.2", "0.3.1");
    NEWER("0.4.0", "0.3.9");
    NEWER("1.0.0", "0.99.99");

    // The whole reason this is not a string compare.
    NEWER("0.10.0", "0.9.0");
    NEWER("0.3.10", "0.3.9");
    NEWER("10.0.0", "9.0.0");

    // A GitHub tag compares directly against CFBundleShortVersionString.
    SAME("v0.3.1", "0.3.1");
    NEWER("v0.4.0", "0.3.1");

    // Missing components are zero, in either direction.
    SAME("0.4", "0.4.0");
    SAME("1", "1.0.0.0");
    NEWER("0.4.1", "0.4");

    // Leading zeros are digits, not octal or text.
    SAME("0.04.0", "0.4.0");

    // Pre-release suffixes sort before the release they lead to.
    NEWER("1.0.0", "1.0.0-rc1");
    NEWER("1.0.0-rc2", "1.0.0-rc1");
    NEWER("1.0.1-rc1", "1.0.0");

    // Garbage must not compare equal to a real version, and must not crash.
    CHECK(version_compare("", "0.0.0") == 0);      // no components either side
    NEWER("0.0.1", "");
    NEWER("0.0.1", "not-a-version");
    CHECK(version_compare("99999999999999999999.0", "0.1") > 0);   // clamped, not wrapped

    printf(failures ? "%d FAILURES\n" : "all version tests passed\n", failures);
    return failures ? 1 : 0;
}
