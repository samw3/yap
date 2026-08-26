#include "degenerate.h"
#include <cstdio>
#include <string>

using yap::looks_degenerate;
using yap::has_tail_loop;
static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); ++failures; } } while (0)

int main() {
    // ---- the regression this was written for ----
    // Observed in the field: 133 chars of output from a 174-char transcript was
    // rejected by the old "trailing 24 chars appears 3+ times anywhere" rule.
    // A normalizer SHORTENING text by 24% is exactly correct behavior.
    {
        const std::string in =
            "um so I think we should uh probably ship the thing on Tuesday you know "
            "unless there's uh some kind of problem with the build I mean the tests "
            "are green so it should be fine";
        const std::string out =
            "I think we should probably ship the thing on Tuesday, unless there's "
            "some kind of problem with the build. The tests are green, so it should "
            "be fine.";
        CHECK(in.size() > out.size());
        CHECK(!looks_degenerate(out, in));
    }

    // ---- legitimate outputs must be accepted ----
    CHECK(!looks_degenerate("Ship it.", "uh ship it"));
    CHECK(!looks_degenerate("Yes.", "yes"));
    CHECK(!looks_degenerate("Send it to sam@kibeam.com by 3:30 p.m.",
                            "send it to sam at kibeam dot com by three thirty pm"));
    // repeated phrase in the MIDDLE is ordinary English, not a loop
    CHECK(!looks_degenerate("I really really really want that feature, and so does everyone else.",
                            "I really really really want that feature and so does everyone else"));
    // a transcript that is mostly filler legitimately shrinks a lot
    CHECK(!looks_degenerate("Okay.", "um uh so like you know um okay"));

    // ---- genuine degeneracy must be rejected ----
    CHECK(looks_degenerate("", "something was said"));
    // runaway growth
    CHECK(looks_degenerate(std::string(400, 'x'), "short input"));
    // actual tail loop
    CHECK(looks_degenerate("The plan is good and so on and so on and so on ",
                           "the plan is good"));
    // severe truncation on a long input
    CHECK(looks_degenerate("ok", std::string(200, 'a') + " and more words here"));

    // ---- has_tail_loop directly ----
    CHECK(has_tail_loop("abcdabcdabcd"));
    CHECK(has_tail_loop("preamble then LOOPLOOPLOOP"));
    CHECK(!has_tail_loop("abcdefghijklmnop"));
    CHECK(!has_tail_loop("ab"));                       // too short to judge
    CHECK(!has_tail_loop(""));
    // two repeats is not yet a loop
    CHECK(!has_tail_loop("xyzwxyzw"));

    printf(failures ? "%d FAILURES\n" : "all degeneracy tests passed\n", failures);
    return failures ? 1 : 0;
}
