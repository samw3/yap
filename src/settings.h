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

// How long an armed-but-unused microphone is held open before the engine is torn
// down. 0 == never: the engine stays up until something else releases it (sleep,
// screen lock, quit), which also means the amber recording indicator stays lit
// and coreaudiod keeps its PreventUserIdleSleep assertion.
double idle_timeout();          // seconds; 0 == never tear the engine down
void   set_idle_timeout(double seconds);

bool launch_at_login();
void set_launch_at_login(bool on);

// The update check is the only thing in Yap that touches the network. With this
// off, nothing in the app ever opens a socket.
bool auto_update_check();
void set_auto_update_check(bool on);

double last_update_check();          // unix time; 0 == never checked
void   set_last_update_check(double when);

}  // namespace settings
}  // namespace yap

#ifdef __OBJC__
#import <Foundation/Foundation.h>
// Posted by set_idle_timeout. A countdown already running was scheduled against
// the old value, so whoever owns the timer has to re-arm it against the new one
// -- without this, choosing "never" still lets the mic sleep at the old deadline.
extern NSString * const YapIdleTimeoutDidChangeNotification;
#endif
