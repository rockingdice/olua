//
// AUTO BUILD, DON'T MODIFY!
//
#include "lua_example.h"
#include "Example.h"
#include "olua-custom.h"

static int _example_Object___gc(lua_State *L)
{
    olua_startinvoke(L);

    olua_endinvoke(L);

    return olua_objgc(L);
}

static int _example_Object___olua_move(lua_State *L)
{
    olua_startinvoke(L);

    auto self = (example::Object *)olua_toobj(L, 1, "example.Object");
    olua_push_obj(L, self, "example.Object");

    olua_endinvoke(L);

    return 1;
}

static int _example_Object_autorelease(lua_State *L)
{
    olua_startinvoke(L);

    example::Object *self = nullptr;

    olua_to_obj(L, 1, &self, "example.Object");

    // example::Object *autorelease()
    example::Object *ret = self->autorelease();
    int num_ret = olua_push_obj(L, ret, "example.Object");

    olua_endinvoke(L);

    return num_ret;
}

static int _example_Object_getReferenceCount(lua_State *L)
{
    olua_startinvoke(L);

    example::Object *self = nullptr;

    olua_to_obj(L, 1, &self, "example.Object");

    // unsigned int getReferenceCount()
    unsigned int ret = self->getReferenceCount();
    int num_ret = olua_push_uint(L, (lua_Unsigned)ret);

    olua_endinvoke(L);

    return num_ret;
}

static int _example_Object_new(lua_State *L)
{
    olua_startinvoke(L);

    // Object()
    example::Object *ret = new example::Object();
    int num_ret = olua_push_obj(L, ret, "example.Object");
    olua_postnew(L, ret);

    olua_endinvoke(L);

    return num_ret;
}

OLUA_BEGIN_DECLS
OLUA_LIB int luaopen_example_Object(lua_State *L)
{
    oluacls_class(L, "example.Object", nullptr);
    oluacls_func(L, "__gc", _example_Object___gc);
    oluacls_func(L, "__olua_move", _example_Object___olua_move);
    oluacls_func(L, "autorelease", _example_Object_autorelease);
    oluacls_func(L, "getReferenceCount", _example_Object_getReferenceCount);
    oluacls_func(L, "new", _example_Object_new);
    oluacls_prop(L, "referenceCount", _example_Object_getReferenceCount, nullptr);

    olua_registerluatype<example::Object>(L, "example.Object");

    return 1;
}
OLUA_END_DECLS

static int _example_Hello___gc(lua_State *L)
{
    olua_startinvoke(L);

    olua_postgc<example::Hello>(L, 1);

    olua_endinvoke(L);

    return 0;
}

static int _example_Hello___olua_move(lua_State *L)
{
    olua_startinvoke(L);

    auto self = (example::Hello *)olua_toobj(L, 1, "example.Hello");
    olua_push_obj(L, self, "example.Hello");

    olua_endinvoke(L);

    return 1;
}

static int _example_Hello_getName(lua_State *L)
{
    olua_startinvoke(L);

    example::Hello *self = nullptr;

    olua_to_obj(L, 1, &self, "example.Hello");

    // const std::string &getName()
    const std::string &ret = self->getName();
    int num_ret = olua_push_std_string(L, ret);

    olua_endinvoke(L);

    return num_ret;
}

static int _example_Hello_getThis(lua_State *L)
{
    olua_startinvoke(L);

    example::Hello *self = nullptr;

    olua_to_obj(L, 1, &self, "example.Hello");

    // std::shared_ptr<example::Hello> getThis()
    std::shared_ptr<example::Hello> ret = self->getThis();
    int num_ret = olua_push_obj(L, &ret, "example.Hello");

    olua_endinvoke(L);

    return num_ret;
}

static int _example_Hello_new(lua_State *L)
{
    olua_startinvoke(L);

    // Hello()
    example::Hello *ret = new example::Hello();
    int num_ret = olua_push_obj(L, ret, "example.Hello");
    olua_postnew(L, ret);

    olua_endinvoke(L);

    return num_ret;
}

static int _example_Hello_say(lua_State *L)
{
    olua_startinvoke(L);

    example::Hello *self = nullptr;

    olua_to_obj(L, 1, &self, "example.Hello");

    // void say()
    self->say();

    olua_endinvoke(L);

    return 0;
}

static int _example_Hello_setName(lua_State *L)
{
    olua_startinvoke(L);

    example::Hello *self = nullptr;
    std::string arg1;       /** value */

    olua_to_obj(L, 1, &self, "example.Hello");
    olua_check_std_string(L, 2, &arg1);

    // void setName(const std::string &value)
    self->setName(arg1);

    olua_endinvoke(L);

    return 0;
}

static int _example_Hello_setThis(lua_State *L)
{
    olua_startinvoke(L);

    example::Hello *self = nullptr;
    std::shared_ptr<example::Hello> arg1;       /** sp */

    olua_to_obj(L, 1, &self, "example.Hello");
    olua_check_obj(L, 2, &arg1, "example.Hello");

    // void setThis(const std::shared_ptr<example::Hello> &sp)
    self->setThis(arg1);

    olua_endinvoke(L);

    return 0;
}

static int _example_Hello_shared_from_this(lua_State *L)
{
    olua_startinvoke(L);

    example::Hello *self = nullptr;

    olua_to_obj(L, 1, &self, "example.Hello");

    // @copyfrom(std::enable_shared_from_this) std::shared_ptr<example::Hello> shared_from_this()
    std::shared_ptr<example::Hello> ret = self->shared_from_this();
    int num_ret = olua_push_obj(L, &ret, "example.Hello");

    olua_endinvoke(L);

    return num_ret;
}

OLUA_BEGIN_DECLS
OLUA_LIB int luaopen_example_Hello(lua_State *L)
{
    oluacls_class(L, "example.Hello", nullptr);
    oluacls_func(L, "__gc", _example_Hello___gc);
    oluacls_func(L, "__olua_move", _example_Hello___olua_move);
    oluacls_func(L, "getName", _example_Hello_getName);
    oluacls_func(L, "getThis", _example_Hello_getThis);
    oluacls_func(L, "new", _example_Hello_new);
    oluacls_func(L, "say", _example_Hello_say);
    oluacls_func(L, "setName", _example_Hello_setName);
    oluacls_func(L, "setThis", _example_Hello_setThis);
    oluacls_func(L, "shared_from_this", _example_Hello_shared_from_this);
    oluacls_prop(L, "name", _example_Hello_getName, _example_Hello_setName);
    oluacls_prop(L, "this", _example_Hello_getThis, _example_Hello_setThis);

    olua_registerluatype<example::Hello>(L, "example.Hello");

    return 1;
}
OLUA_END_DECLS

OLUA_BEGIN_DECLS
OLUA_LIB int luaopen_example(lua_State *L)
{
    olua_require(L, "example.Object", luaopen_example_Object);
    olua_require(L, "example.Hello", luaopen_example_Hello);

    return 0;
}
OLUA_END_DECLS
