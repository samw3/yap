#pragma once
#include "normalizer.h"
#include <string>

namespace yap {

// Persisted in NSUserDefaults so they survive relaunch. The control line is part
// of the format s1-mini was trained on, so these are real model inputs, not
// cosmetic preferences.
namespace settings {

Style style();
void  set_styling(Style::Styling s);
void  set_structure(Style::Structure s);
void  set_context(Style::Context c);

double idle_timeout();          // seconds; 0 == never tear the engine down
void   set_idle_timeout(double seconds);

bool launch_at_login();
void set_launch_at_login(bool on);

}  // namespace settings
}  // namespace yap
