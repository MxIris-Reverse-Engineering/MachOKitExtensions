// The class index demo: one C++ file that `ClassIndexDemoTests` compiles
// twice and then prints what `CPlusPlusClassIndexStore` recovers.
//
// - With `-DCLASS_INDEX_DEMO_LIBRARY` it is `libZoo.dylib`, which exports
//   `zoo::Animal` with its symbols.
// - Without it, it is `libFarm.dylib`: classes deriving from `zoo::Animal`
//   and from each other, all hidden, linked against `libZoo.dylib` through
//   `@rpath` and stripped with `strip -x`. Their functions lose their names;
//   their typeinfos and vtables stay.
//
// By hand:
//
//   xcrun clang++ -dynamiclib -DCLASS_INDEX_DEMO_LIBRARY ClassIndexDemo.cpp -o libZoo.dylib -install_name @rpath/libZoo.dylib
//   xcrun clang++ -dynamiclib ClassIndexDemo.cpp -o libFarm.dylib -install_name @rpath/libFarm.dylib -L. -lZoo
//   xcrun strip -x libFarm.dylib

#include <exception>

namespace zoo {

class __attribute__((visibility("default"))) Animal {
public:
    virtual ~Animal();
    virtual const char *name() const;
    virtual int legs() const;
    virtual void speak();
};

} // namespace zoo

#if defined(CLASS_INDEX_DEMO_LIBRARY)

namespace zoo {

Animal::~Animal() {}
const char *Animal::name() const { return "animal"; }
int Animal::legs() const { return 4; }
void Animal::speak() {}

} // namespace zoo

#else

#define DEMO_HIDDEN __attribute__((visibility("hidden")))

namespace farm {

// Single inheritance from a class of another image: overrides `name` and
// `speak`, keeps `legs`, adds `fetch`.
class DEMO_HIDDEN Dog : public zoo::Animal {
public:
    ~Dog() override;
    const char *name() const override;
    void speak() override;
    virtual void fetch();
};
Dog::~Dog() {}
const char *Dog::name() const { return "dog"; }
void Dog::speak() {}
void Dog::fetch() {}

// Multiple inheritance: `Swimmer` gets a secondary vtable of its own.
class DEMO_HIDDEN Swimmer {
public:
    virtual ~Swimmer();
    virtual int strokes();
    long lanes = 1;
};
Swimmer::~Swimmer() {}
int Swimmer::strokes() { return 1; }

class DEMO_HIDDEN Duck : public zoo::Animal, public Swimmer {
public:
    int legs() const override;
    int strokes() override;
    virtual void quack();
};
int Duck::legs() const { return 2; }
int Duck::strokes() { return 3; }
void Duck::quack() {}

// Virtual inheritance: `Named` sits at an offset the vtable stores.
struct DEMO_HIDDEN Named {
    virtual ~Named();
    virtual const char *label();
    long identifier = 0;
};
Named::~Named() {}
const char *Named::label() { return "named"; }

struct DEMO_HIDDEN Pet : virtual Named {
    const char *label() override;
    virtual int age();
};
const char *Pet::label() { return "pet"; }
int Pet::age() { return 3; }

// A pure virtual function, and a deleted one.
struct DEMO_HIDDEN Shape {
    virtual ~Shape();
    virtual double area() const = 0;
    virtual void resize() = delete;
};
Shape::~Shape() {}

struct DEMO_HIDDEN Square : Shape {
    double area() const override;
};
double Square::area() const { return 4; }

// A base of the system: libc++abi's `std::exception`.
struct DEMO_HIDDEN FarmError : std::exception {
    const char *what() const noexcept override;
};
const char *FarmError::what() const noexcept { return "farm error"; }

// No key function and default visibility: every image keeps a hidden copy
// of the typeinfo, which Apple arm64 marks as not unique.
template <typename Element>
struct Box {
    virtual ~Box() {}
    virtual Element get() const { return Element(); }
};

} // namespace farm

// Uses every class through a base pointer, so that no build drops a vtable.
extern "C" __attribute__((visibility("default"))) int classIndexDemoTouch(void) {
    int total = 0;
    zoo::Animal *animals[] = {new farm::Dog(), new farm::Duck()};
    for (zoo::Animal *animal : animals) {
        animal->speak();
        total += animal->legs() + animal->name()[0];
        delete animal;
    }
    farm::Swimmer *swimmer = new farm::Duck();
    total += swimmer->strokes();
    delete swimmer;
    farm::Named *named = new farm::Pet();
    total += named->label()[0];
    delete named;
    farm::Shape *shape = new farm::Square();
    total += static_cast<int>(shape->area());
    delete shape;
    std::exception *error = new farm::FarmError();
    total += error->what()[0];
    delete error;
    farm::Box<int> *box = new farm::Box<int>();
    total += box->get();
    delete box;
    return total;
}

#endif
