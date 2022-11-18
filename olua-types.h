/**
 * The MIT License (MIT)
 *
 * Copyright (c) 2019-2022 codetypes@gmail.com
 *
 * https://github.com/zhongfq/olua
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 * the Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 * FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 * COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 * IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#ifndef __OLUA_TYPES_H__
#define __OLUA_TYPES_H__

#include "olua.h"


#if defined(_MSC_VER) && !defined(_SSIZE_T)
#include <BaseTsd.h>
#define _SSIZE_T
typedef SSIZE_T ssize_t;
#endif

namespace olua {

template<class T>
class pointer {
public:
    pointer(const pointer &) = delete;
    pointer &operator=(const pointer &) = delete;
    
    pointer() {}
    ~pointer()
    {
        if (_owner) {
            delete[] _data;
        }
    }
    
    pointer(const T *v)
    :_len(0)
    ,_owner(false)
    ,_data(v)
    {}
    
    static pointer<T> *array(size_t len)
    {
        pointer<T> *ret = new pointer<T>();
        ret->_len = len;
        ret->_data = new T[len]();
        return ret;
    }

    OLUA_NAME(new) static pointer<T> *create(const T &v)
    {
        pointer<T> *ret = new pointer<T>();
        ret->_len = 1;
        ret->_data = new T[1]();
        ret->_data[0] = v;
        return ret;
    }
    
    T __index(unsigned idx)
    {
         olua_assert(idx >= 1 && idx <= _len, "index out of range");
         return _data[idx - 1];
    }
    
    void __newindex(unsigned idx, const T &v)
    {
        olua_assert(idx >= 1 && idx <= _len, "index out of range");
        _data[idx - 1] = v;
    }

    void take() {_owner = false;}

    olua_Return tostring(lua_State *L, size_t len = -1)
    {
        olua_assert(_len > 0, "length <= 0");
        if (len == -1) {
            len = _len;
        }
        olua_assert(len <= _len, "length too long");
        lua_pushlstring(L, (const char*)_data, len * sizeof(T));
        return 1;
    }

    OLUA_GETTER OLUA_NAME(length) size_t getLength() {return _len;}
    OLUA_SETTER OLUA_NAME(length) void setLength(size_t len)
    {
        olua_assert(!_owner, "not allow set length when own the data");
        _len = len;
    }

    void copyfrom(pointer<T> *obj, size_t from = 1, size_t len = -1, size_t to = 1)
    {
        from--;
        to--;
        olua_assert(from < obj->_len, "invalid 'from' position");
        if (len == -1) {
            len = obj->_len - from;
        }
        olua_assert(from + len <= obj->_len, "data not enough to copy ");
        olua_assert(to + len <= _len, "no enough space to store data");
        for (size_t i = 0; i < len; i++) {
            _data[to++] = obj->_data[from++];
        }
    }

    void fill(const char *data, size_t len)
    {
        olua_assert(sizeof(T) == sizeof(char), "miss match sizeof");
        olua_assert(len <= _len, "data too long");
        strncpy((char *)_data, data, len);
    }

    pointer<T> *sub(size_t from, size_t to = -1)
    {
        if (to == -1) {
            to = _len;
        }
        from--;
        to--;
        olua_assert(from < _len, "invalid 'from' position");
        olua_assert(to < _len, "invalid 'to' position");
        olua_assert(from <= to, "invalid 'from' position");
        pointer<T> *ret = array(to - from + 1);
        for (size_t i = 0; i < ret->_len; i++) {
            ret->_data[i] = _data[from + i];
        }
        return ret;
    }
    
    OLUA_GETTER const T &value() {return *_data;}
    OLUA_EXCLUDE T *data() {return _data;}
    OLUA_EXCLUDE size_t length() {return _len;}
private:
    T *_data = nullptr;
    size_t _len = 0;
    bool _owner = true;
};
}

typedef olua::pointer<bool> olua_bool;
typedef olua::pointer<std::string> olua_string;
typedef olua::pointer<int8_t> olua_int8;
typedef olua::pointer<uint8_t> olua_uint8;
typedef olua::pointer<int16_t> olua_int16;
typedef olua::pointer<uint16_t> olua_uint16;
typedef olua::pointer<int32_t> olua_int32;
typedef olua::pointer<uint32_t> olua_uint32;
typedef olua::pointer<int64_t> olua_int64;
typedef olua::pointer<uint64_t> olua_uint64;
typedef olua::pointer<float> olua_float;
typedef olua::pointer<double> olua_double;
typedef olua::pointer<long double> olua_long_double;
typedef olua::pointer<size_t> olua_size_t;
typedef olua::pointer<ssize_t> olua_ssize_t;
typedef olua::pointer<time_t> olua_time_t;

static inline int olua_is_pointer(lua_State *L, int idx, const char *cls)
{
    return olua_isa(L, idx, cls);
}

template <class T>
void olua_check_pointer(lua_State *L, int idx, T **value, const char *cls)
{
    olua::pointer<T> *obj = (olua::pointer<T> *)olua_checkobj(L, idx, cls);
    *value = obj->data();
}

template <class T>
int olua_push_pointer(lua_State *L, T *value, const char *cls)
{
    olua::pointer<T> *obj = new olua::pointer<T>(value);
    olua_pushobj<olua::pointer<T>>(L, obj, cls);
    olua_postnew(L, obj);
    return 1;
}

#endif
