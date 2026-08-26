#include "utf8.h"
#include <cstdio>
#include <string>

using yap::complete_utf8_prefix;
static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); ++failures; } } while (0)

int main() {
    CHECK(complete_utf8_prefix("") == 0);
    CHECK(complete_utf8_prefix("hello") == 5);

    // 2-byte: é = C3 A9
    CHECK(complete_utf8_prefix("a\xC3\xA9") == 3);      // complete
    CHECK(complete_utf8_prefix("a\xC3")     == 1);      // truncated -> hold it back

    // 3-byte: € = E2 82 AC
    CHECK(complete_utf8_prefix("x\xE2\x82\xAC") == 4);
    CHECK(complete_utf8_prefix("x\xE2\x82")     == 1);
    CHECK(complete_utf8_prefix("x\xE2")         == 1);

    // 4-byte: 😀 = F0 9F 98 80
    CHECK(complete_utf8_prefix("\xF0\x9F\x98\x80") == 4);
    CHECK(complete_utf8_prefix("\xF0\x9F\x98")     == 0);
    CHECK(complete_utf8_prefix("\xF0\x9F")         == 0);
    CHECK(complete_utf8_prefix("\xF0")             == 0);

    // complete sequence followed by a truncated one
    CHECK(complete_utf8_prefix("\xC3\xA9\xF0\x9F") == 2);

    // malformed: bare continuation bytes must not stall the stream
    CHECK(complete_utf8_prefix("\x80\x80") == 2);
    CHECK(complete_utf8_prefix("ok\x80")   == 3);

    // reassembling a split emoji across two "tokens" yields the whole thing
    {
        const std::string a = "hi \xF0\x9F";
        const std::string b = "\x98\x80!";
        std::string pending = a;
        std::string out;
        size_t g = complete_utf8_prefix(pending);
        out.append(pending, 0, g);
        pending.erase(0, g);
        CHECK(out == "hi ");
        pending += b;
        g = complete_utf8_prefix(pending);
        out.append(pending, 0, g);
        pending.erase(0, g);
        CHECK(out == "hi \xF0\x9F\x98\x80!");
        CHECK(pending.empty());
    }

    printf(failures ? "%d FAILURES\n" : "all utf8 tests passed\n", failures);
    return failures ? 1 : 0;
}
