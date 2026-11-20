#include "CPlusPlusSymbolsFixture.h"

#include <exception>
#include <vector>

// Everything is `used` and out of line, so that release builds and the
// linker's dead stripping keep each symbol the tests look for.
#define FIXTURE_KEEP __attribute__((used, noinline))

namespace fixture {

// A constructor shows a class.
class WithConstructor {
public:
    WithConstructor();
    int value;
};
FIXTURE_KEEP WithConstructor::WithConstructor() : value(1) {}

// A polymorphic class: its vtable and typeinfo sit in it.
class Polymorphic {
public:
    virtual ~Polymorphic();
    virtual int answer();
};
FIXTURE_KEEP Polymorphic::~Polymorphic() {}
FIXTURE_KEEP int Polymorphic::answer() { return 42; }

// Virtual inheritance: a VTT, a construction vtable and virtual thunks.
struct VirtualBase {
    virtual ~VirtualBase();
    virtual int run();
};
struct Intermediate : virtual VirtualBase {
    int run() override;
};
struct Complete : Intermediate {
    int run() override;
};
FIXTURE_KEEP VirtualBase::~VirtualBase() {}
FIXTURE_KEEP int VirtualBase::run() { return 1; }
FIXTURE_KEEP int Intermediate::run() { return 2; }
FIXTURE_KEEP int Complete::run() { return 3; }

// Only a const member function: a class by its qualifier.
struct ConstOnly {
    int read() const;
};
FIXTURE_KEEP int ConstOnly::read() const { return 4; }

// Only a static member function: nothing tells it from a namespace.
struct StaticOnly {
    static int make();
};
FIXTURE_KEEP int StaticOnly::make() { return 5; }

// A static member function, and a use as a parameter type elsewhere: a type
// by that use alone.
struct Token {
    static int count();
};
FIXTURE_KEEP int Token::count() { return 6; }
FIXTURE_KEEP int consume(Token *token) { return token == nullptr ? 0 : 7; }

// Declared only, and used only as a parameter type: no scope of its own.
struct Opaque;
FIXTURE_KEEP int take(Opaque *opaque) { return opaque == nullptr ? 8 : 0; }

// Two specializations of one class template.
template <typename Element>
struct Box {
    Element stored;
    Element get() const;
};
template <typename Element>
FIXTURE_KEEP Element Box<Element>::get() const { return stored; }
template struct Box<int>;
template struct Box<char>;

// A function template specialization.
template <typename Element>
FIXTURE_KEEP Element twice(Element value) { return value + value; }
template int twice<int>(int);

// A local class and a lambda inside a function. clang names a closure type in
// a function that is neither inline nor a template `$_0`, not Itanium's
// `'lambda'`. The lambdas take the function's argument: with a constant one,
// an optimized build folds the call and drops the call operator.
FIXTURE_KEEP int localThing(int seed) {
    struct Local {
        FIXTURE_KEEP int get() { return 9; }
    };
    auto addOne = [](int value) __attribute__((noinline)) { return value + 1; };
    return Local().get() + addOne(seed);
}

// A lambda inside an inline function: its closure type has the Itanium name.
inline FIXTURE_KEEP int withLambda(int seed) {
    auto addTwo = [](int value) __attribute__((noinline)) { return value + 2; };
    return addTwo(seed);
}

// The standard library, instantiated here.
FIXTURE_KEEP int sumOfVector() {
    std::vector<int> values{1, 2, 3};
    int sum = 0;
    for (int value : values) {
        sum += value;
    }
    return sum;
}

namespace {
FIXTURE_KEEP int hidden() { return 11; }
} // namespace

FIXTURE_KEEP int callHidden() { return hidden(); }

} // namespace fixture

// Class hierarchies for the class index: their typeinfos and vtables.
namespace hierarchy {

// Multiple inheritance: a secondary vtable for `Right`, reached through a
// non-virtual thunk.
struct Left {
    virtual ~Left();
    virtual int left();
    long leftValue = 1;
};
struct Right {
    virtual ~Right();
    virtual int right();
    long rightValue = 2;
};
struct Both : Left, Right {
    int right() override;
    virtual int both();
};
FIXTURE_KEEP Left::~Left() {}
FIXTURE_KEEP int Left::left() { return 1; }
FIXTURE_KEEP Right::~Right() {}
FIXTURE_KEEP int Right::right() { return 2; }
FIXTURE_KEEP int Both::right() { return 3; }
FIXTURE_KEEP int Both::both() { return 4; }

// A pure virtual function, and a class implementing it.
struct Shape {
    virtual ~Shape();
    virtual int area() = 0;
};
struct Square : Shape {
    int area() override;
};
FIXTURE_KEEP Shape::~Shape() {}
FIXTURE_KEEP int Square::area() { return 5; }

// A deleted virtual function.
struct Retired {
    virtual ~Retired();
    virtual int kept();
    virtual void gone() = delete;
};
FIXTURE_KEEP Retired::~Retired() {}
FIXTURE_KEEP int Retired::kept() { return 6; }

// A base in another image: libc++abi's `std::exception`.
struct Failure : std::exception {
    const char *what() const noexcept override;
};
FIXTURE_KEEP const char *Failure::what() const noexcept { return "failure"; }

// No key function and hidden: on Apple arm64 its typeinfo is not unique.
struct __attribute__((visibility("hidden"))) HiddenInline {
    virtual ~HiddenInline() {}
    virtual int value() { return 7; }
};

namespace {
struct Anonymous : Left {
    int left() override { return 8; }
};
} // namespace

// Calls through base pointers, so that no build devirtualizes the calls
// and drops a vtable.
FIXTURE_KEEP int callLeft(Left *object) { return object->left(); }
FIXTURE_KEEP int callRight(Right *object) { return object->right(); }
FIXTURE_KEEP int callArea(Shape *object) { return object->area(); }
FIXTURE_KEEP int callKept(Retired *object) { return object->kept(); }
FIXTURE_KEEP int callWhat(std::exception *object) { return object->what()[0]; }
FIXTURE_KEEP int callValue(HiddenInline *object) { return object->value(); }

FIXTURE_KEEP int touchHierarchies() {
    Both *both = new Both();
    Square *square = new Square();
    Retired *retired = new Retired();
    Failure *failure = new Failure();
    HiddenInline *hiddenInline = new HiddenInline();
    Left *anonymous = new Anonymous();
    int total = callLeft(both) + callRight(both) + both->both() + callArea(square) + callKept(retired) + callWhat(failure) + callValue(hiddenInline) + callLeft(anonymous);
    delete both;
    delete square;
    delete retired;
    delete failure;
    delete hiddenInline;
    delete anonymous;
    return total;
}

} // namespace hierarchy

// A name with the C++ prefix that is no Itanium name.
extern "C" FIXTURE_KEEP int fixtureUnparsable(void) __asm__("__Z_fixture_unparsable");
extern "C" int fixtureUnparsable(void) { return 12; }

extern "C" const void *CPlusPlusSymbolsFixtureAnchor(void) {
    return reinterpret_cast<const void *>(&CPlusPlusSymbolsFixtureAnchor);
}

extern "C" int CPlusPlusSymbolsFixtureTouchEverything(void) {
    using namespace fixture;
    int total = WithConstructor().value;
    Polymorphic polymorphic;
    total += polymorphic.answer();
    Complete complete;
    total += complete.run();
    total += ConstOnly().read();
    total += StaticOnly::make();
    total += Token::count() + consume(nullptr) + take(nullptr);
    total += Box<int>{13}.get() + Box<char>{1}.get();
    total += twice(7);
    total += localThing(total) + withLambda(total);
    total += sumOfVector();
    total += callHidden();
    total += fixtureUnparsable();
    total += hierarchy::touchHierarchies();
    return total;
}
