local olua = require "olua"

local format = olua.format

local function gen_push_func(cv, write)
    local num_args = #cv.vars
    local codeset = {push_args = olua.newarray():push('')}

    for i, var in ipairs(cv.vars) do
        local pi = var.set.args[1]
        codeset.push_args:push(i > 1 and '' or nil)
        local length = (pi.attr.array or {})[1]
        if length then
            local subset = {push_args = olua.newarray()}
            olua.gen_push_exp(pi, "obj", subset)
            codeset.push_args:pushf([[
                lua_createtable(L, ${length}, 0);
                for (int i = 0; i < ${length}; i++) {
                    ${pi.type.cppcls} obj = value->${pi.varname}[i];
                    ${subset.push_args}
                    olua_rawseti(L, -2, i + 1);
                }
            ]])
        else
            local argname = format('value->${pi.varname}')
            olua.gen_push_exp(pi, argname, codeset)
        end
        codeset.push_args:pushf([[olua_setfield(L, -2, "${pi.varname}");]])
    end

    write(format([[
        int olua_push_${{cv.cppcls}}(lua_State *L, const ${cv.cppcls} *value)
        {
            if (value) {
                lua_createtable(L, 0, ${num_args});
                ${codeset.push_args}
            } else {
                lua_pushnil(L);
            }

            return 1;
        }
    ]]))
end

local function gen_check_func(cv, write)
    local codeset = {
        decl_args = olua.newarray(),
        check_args = olua.newarray(),
    }
    for i, var in ipairs(cv.vars) do
        local pi = var.set.args[1]
        local length = (pi.attr.array or {})[1]
        if length then
            local subset = {decl_args = olua.newarray(), check_args = olua.newarray()}
            olua.gen_decl_exp(pi, "obj", subset)
            olua.gen_check_exp(pi, "obj", -1, subset)
            codeset.check_args:pushf([[
                if (olua_getfield(L, idx, "${pi.varname}") != LUA_TTABLE) {
                    luaL_error(L, "field '${pi.varname}' is not a table");
                }
                for (int i = 0; i < ${length}; i++) {
                    ${subset.decl_args}
                    olua_rawgeti(L, -1, i + 1);
                    if (!olua_isnoneornil(L, -1)) {
                        ${subset.check_args}
                    }
                    value->${pi.varname}[i] = obj;
                    lua_pop(L, 1);
                }
                lua_pop(L, 1);
            ]])
        else
            local argname = 'arg' .. i
            olua.gen_decl_exp(pi, argname, codeset)
            codeset.check_args:pushf([[olua_getfield(L, idx, "${pi.varname}");]])
            if pi.attr.optional then
                local subset = {check_args = olua.newarray()}
                olua.gen_check_exp(pi, argname, -1, subset)
                codeset.check_args:pushf([[
                    if (!olua_isnoneornil(L, -1)) {
                        ${subset.check_args}
                        value->${pi.varname} = (${pi.decltype})${argname};
                    }
                    lua_pop(L, 1);
                ]])
            else
                olua.gen_check_exp(pi, argname, -1, codeset)
                codeset.check_args:pushf([[
                    value->${pi.varname} = (${pi.decltype})${argname};
                    lua_pop(L, 1);
                ]])
            end
        end
        codeset.check_args:push('')
    end

    write(format([[
        void olua_check_${{cv.cppcls}}(lua_State *L, int idx, ${cv.cppcls} *value)
        {
            if (!value) {
                luaL_error(L, "value is NULL");
            }
            idx = lua_absindex(L, idx);
            luaL_checktype(L, idx, LUA_TTABLE);

            ${codeset.decl_args}

            ${codeset.check_args}
        }
    ]]))
end

local function gen_pack_func(cv, write)
    local codeset = {
        decl_args = olua.newarray(),
        check_args = olua.newarray(),
    }
    for i, var in ipairs(cv.vars) do
        local pi = var.set.args[1]
        local length = (pi.attr.array or {})[1]
        if length then
            codeset.decl_args:clear()
            codeset.check_args:clear()
            codeset.check_args:pushf([[luaL_error(L, "${cv.cppcls} not support 'pack'");]])
            break
        end

        local argname = 'arg' .. i
        olua.gen_decl_exp(pi, argname, codeset)
        olua.gen_check_exp(pi, argname, 'idx + ' ..  (i - 1), codeset)
        codeset.check_args:pushf([[
            value->${pi.varname} = (${pi.decltype})${argname};
        ]])
        codeset.check_args:push('')
    end

    write(format([[
        void olua_pack_${{cv.cppcls}}(lua_State *L, int idx, ${cv.cppcls} *value)
        {
            if (!value) {
                luaL_error(L, "value is NULL");
            }
            idx = lua_absindex(L, idx);

            ${codeset.decl_args}

            ${codeset.check_args}
        }
    ]]))
end

local function gen_unpack_func(cv, write)
    local num_args = #cv.vars
    local codeset = {push_args = olua.newarray():push('')}
    for _, var in ipairs(cv.vars) do
        local pi = var.set.args[1]
        local length = (pi.attr.array or {})[1]
        if length then
            codeset.push_args:clear()
            codeset.push_args:pushf([[luaL_error(L, "${cv.cppcls} not support 'unpack'");]])
            break
        end

        local argname = format('value->${pi.varname}')
        olua.gen_push_exp(pi, argname, codeset)
    end

    write(format([[
        int olua_unpack_${{cv.cppcls}}(lua_State *L, const ${cv.cppcls} *value)
        {
            if (value) {
                ${codeset.push_args}
            } else {
                for (int i = 0; i < ${num_args}; i++) {
                    lua_pushnil(L);
                }
            }

            return ${num_args};
        }
    ]]))
end

local function gen_is_func(cv, write)
    local exps = olua.newarray(' && ')
    exps:push('olua_istable(L, idx)')
    for i = #cv.vars, 1, -1 do
        local var = cv.vars[i]
        local pi = var.set.args[1]
        if not pi.attr.optional then
            exps:pushf('olua_hasfield(L, idx, "${pi.varname}")')
        end
    end
    write(format([[
        bool olua_is_${{cv.cppcls}}(lua_State *L, int idx)
        {
            return ${exps};
        }
    ]]))
end

local function gen_canpack_func(cv, write)
    local exps = olua.newarray(' && ')
    for i, var in ipairs(cv.vars) do
        local pi = var.set.args[1]
        local func_is = olua.conv_func(pi.type, 'is')
        local N = i - 1
        if olua.is_pointer_type(pi.type) then
            exps:pushf('${func_is}(L, idx + ${N}, "${pi.type.luacls}")')
        else
            exps:pushf('${func_is}(L, idx + ${N})')
        end
    end
    write(format([[
        bool olua_canpack_${{cv.cppcls}}(lua_State *L, int idx)
        {
            return ${exps};
        }
    ]]))
end

function olua.gen_conv_header(module, write)
    for _, cv in ipairs(module.convs) do
        local ifdef = cv.ifdef
        write(ifdef)
        write(format([[
            // ${cv.cppcls}
            int olua_push_${{cv.cppcls}}(lua_State *L, const ${cv.cppcls} *value);
            void olua_check_${{cv.cppcls}}(lua_State *L, int idx, ${cv.cppcls} *value);
            bool olua_is_${{cv.cppcls}}(lua_State *L, int idx);
            void olua_pack_${{cv.cppcls}}(lua_State *L, int idx, ${cv.cppcls} *value);
            int olua_unpack_${{cv.cppcls}}(lua_State *L, const ${cv.cppcls} *value);
            bool olua_canpack_${{cv.cppcls}}(lua_State *L, int idx);
        ]]))
        write(ifdef and '#endif' or nil)
        write("")
    end

    for _, cls in ipairs(module.class_types) do
        local ti = olua.typeinfo(cls.cppcls, nil, true)
        if olua.is_func_type(cls) then
            local ifdef = cls.ifdefs['*']
            write(ifdef)
            write(format([[
                // ${cls.cppcls}
                bool olua_is_${{cls.cppcls}}(lua_State *L, int idx);
                int olua_push_${{cls.cppcls}}(lua_State *L, const ${cls.cppcls} *value);
                void olua_check_${{cls.cppcls}}(lua_State *L, int idx, ${cls.cppcls} *value);
            ]]))
            write(ifdef and '#endif' or nil)
            write("")
        end
    end
end

local function gen_cb_is_func(cls, write)
    write(format([[
        bool olua_is_${{cls.cppcls}}(lua_State *L, int idx)
        {
            return olua_is_callback<${cls.cppcls}>(L, idx);
        }
    ]]))
end

local function gen_cb_push_func(cls, write)
    write(format([[
        int olua_push_${{cls.cppcls}}(lua_State *L, const ${cls.cppcls} *value)
        {
            return olua_push_callback<${cls.cppcls}>(L, value);
        }
    ]]))
end

local function gen_cb_check_func(cls, write)
    write(format([[
        void olua_check_${{cls.cppcls}}(lua_State *L, int idx, ${cls.cppcls} *value)
        {
            olua_check_callback<${cls.cppcls}>(L, idx, value);
        }
    ]]))
end

function olua.gen_conv_source(module, write)
    for _, cv in ipairs(module.convs) do
        local ifdef = cv.ifdef
        write(ifdef)
        gen_push_func(cv, write)
        write('')
        gen_check_func(cv, write)
        write('')
        gen_is_func(cv, write)
        write('')
        gen_pack_func(cv, write)
        write('')
        gen_unpack_func(cv, write)
        write('')
        gen_canpack_func(cv, write)
        write(ifdef and '#endif' or nil)
        write('')
    end

    for _, cls in ipairs(module.class_types) do
        local ti = olua.typeinfo(cls.cppcls, nil, true)
        if olua.is_func_type(cls) then
            local ifdef = cls.ifdefs['*']
            write(ifdef)
            gen_cb_is_func(cls, write)
            write('')
            gen_cb_push_func(cls, write)
            write('')
            gen_cb_check_func(cls, write)
            write(ifdef and '#endif' or nil)
            write('')
        end
    end
end