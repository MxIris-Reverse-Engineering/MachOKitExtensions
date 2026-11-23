#ifndef CPLUSPLUS_SYMBOLS_FIXTURE_H
#define CPLUSPLUS_SYMBOLS_FIXTURE_H

// C++ code with known symbols for the C++ symbol index tests: every kind of
// evidence a scope can show, and a few that show none. The tests find the
// image it is linked into through `CPlusPlusSymbolsFixtureAnchor`.

#ifdef __cplusplus
extern "C" {
#endif

/// An address inside the image the fixture is linked into.
const void *CPlusPlusSymbolsFixtureAnchor(void);

/// Runs every function of the fixture once, so that each is emitted and
/// kept; returns a value that depends on all of them.
int CPlusPlusSymbolsFixtureTouchEverything(void);

#ifdef __cplusplus
}
#endif

#endif
