local olua = require "olua"
local clang = require "clang"

if not olua.isdir('autobuild') then
    olua.mkdir('autobuild')
end

-- auto export after config
if _G.OLUA_AUTO_BUILD == nil then
    _G.OLUA_AUTO_BUILD = true
end

-- auto generate property
if _G.OLUA_AUTO_GEN_PROP == nil then
    _G.OLUA_AUTO_GEN_PROP = true
end

-- enable auto export parent
if _G.OLUA_AUTO_EXPORT_PARENT == nil then
    _G.OLUA_AUTO_EXPORT_PARENT = false
end

-- enable var or method name with underscore
if _G.OLUA_ENABLE_WITH_UNDERSCORE == nil then
    _G.OLUA_ENABLE_WITH_UNDERSCORE = false
end

local format = olua.format
local clang_tu

local template_cursors = {}
local exclude_types = {}
local ignored_types = {}
local visited_types = {}
local alias_types = {}
local type_convs = {}
local module_files = olua.newarray()
local logfile = io.open('autobuild/autoconf.log', 'w')
local deferred = {clang_args = {}, modules = olua.newarray()}
local metamethod = {
    __index = true, __newindex = true,
    __gc = true, __pairs = true, __len = true, __eq = true, __tostring = true,
    __add = true, __sub = true, __mul = true, __mod = true, __pow = true,
    __div = true, __idiv = true,
    __band = true, __bor = true, __bxor = true, __shl = true, __shr = true,
    __unm = true, __bnot = true, __lt = true, __le = true,
    __concat = true, __call = true, __close = true
}

local M = {}

local kFLAG_POINTEE = 1 << 1     -- pointee type
local kFLAG_ENUM = 1 << 2        -- enum type
local kFLAG_ALIAS = 1 << 3       -- alias type
local kFLAG_CONV = 1 << 4        -- conv type
local kFLAG_FUNC = 1 << 5        -- function type
local kFLAG_STRUCT = 1 << 6      -- struct type
local kFLAG_TEMPLATE = 1 << 7    -- template type

local function has_kflag(cls, kind)
    return ((cls.kind or 0) & kind) ~= 0
end

local function conv_func(cls)
    return 'olua_$$_' .. string.gsub(cls.cppcls, '::', '_')
end

local function log(fmt, ...)
    logfile:write(string.format(fmt, ...))
    logfile:write('\n')
end

local function is_templdate_type(tn)
    return tn:find('<')
end

function M:parse()
    assert(not self.class_file)
    assert(not self.type_file)
    local filename = self.name:gsub('_', '-')
    self.class_file = format('autobuild/autogen-${filename}.lua')
    self.type_file = format('autobuild/autogen-${filename}-types.lua')

    module_files:push(self)

    for cls in pairs(exclude_types) do
        ignored_types[cls] = false
    end

    for _, cls in ipairs(self.typedef_types) do
        if not cls.conv then
            if cls.decltype then
                local ti = olua.typeinfo(cls.decltype, nil, true)
                if not ti then
                    error(string.format("decltype '%s' for '%s' is not found",
                        cls.decltype, cls.cppcls))
                end
                cls.conv = ti.conv
            else
                cls.conv = conv_func(cls)
            end
        end
        type_convs[cls.cppcls] = cls.conv
    end

    for _, cls in pairs(self.class_types) do
        if has_kflag(cls, kFLAG_CONV) then
            type_convs[cls.cppcls] = conv_func(cls)
        else
            type_convs[cls.cppcls] = true
        end
    end

    self:visit(clang_tu:cursor())
    self:check_class()
end

function M:has_define_class(cls)
    local name = string.match(cls.cppcls, '[^:]+$')
    return string.find(cls.chunk or '', 'class +' .. name) ~= nil
end

function M:check_class()
    for _, cls in ipairs(self.class_types) do
        if not visited_types[cls.cppcls] then
            if #cls.funcs > 0 or #cls.props > 0 then
                cls.kind = cls.kind or kFLAG_POINTEE
                cls.reg_luatype = self:has_define_class(cls)
                self:do_visit(cls)
            else
                error(format([[
                    class not found: ${cls.cppcls}
                      *** add include header file in your config file or check the class name
                ]]))
            end
        end
    end
    for _, cls in ipairs(self.class_types) do
        for supercls in pairs(cls.supers) do
            if not visited_types[supercls]then
                error(format('super class not found: ${cls.cppcls} -> ${supercls}'))
            end
        end
    end
end

function M:is_excluded_typename(name)
    if exclude_types[name] then
        return true
    elseif string.find(name, '<') then
        return self:is_excluded_typename(name:gsub('<.*>', ''))
    end
end

function M:is_excluded_type(type)
    if type.kind == 'IncompleteArray' then
        return true
    end

    local tn = self:typename(type)-- or type.name
    -- remove const and &
    -- const T * => T *
    -- const T & => T
    local rawtn = tn:gsub('^const ', ''):gsub(' *&$', '')
    if is_templdate_type(rawtn) then
        for _, subtype in ipairs(type.templateArgTypes) do
            if self:is_excluded_type(subtype) then
                return true
            end
        end
    end
    return self:is_excluded_typename(rawtn)
end

function M:parse_typename_from_tree(type)
    local cur = type.declaration
    local name_without_const = type.name:gsub('const ', '')
    if name_without_const:find('^std::') then
        return name_without_const:match('[^< ]+')
    else
        local ns = olua.newarray('::')
        while cur and cur.kind ~= 'TranslationUnit' do
            local value = cur.name:match('[^ ]+$')
            if value then
                ns:insert(value)
                cur = cur.parent
            else
                break
            end
        end
        return tostring(ns)
    end
end

function M:parse_typename_from_type(type, template_types)
    local kind = type.kind
    local name = type.name
    local template_arg_types = type.templateArgTypes
    if #template_arg_types > 0 then
        local has_const = name:find('^const ')
        local exps = olua.newarray('')
        local tn = self:parse_typename_from_tree(type)
        exps:push(has_const and 'const ' or nil)
        exps:push(tn)
        if is_templdate_type(name) then
            exps:push('<')
            for i, v in ipairs(template_arg_types) do
                exps:push(i > 1 and ', ' or nil)
                exps:push(self:parse_typename_from_type(v, template_types))
            end
            exps:push('>')
        end
        return tostring(exps)
    elseif kind == 'LValueReference' then
        return self:parse_typename_from_type(type.pointeeType, template_types) .. ' &'
    elseif kind == 'RValueReference' then
        return self:parse_typename_from_type(type.pointeeType, template_types) .. ' &&'
    elseif kind == 'Pointer' then
        if type.pointeeType.kind == 'Pointer' then
            return self:parse_typename_from_type(type.pointeeType, template_types) .. '*'
        else
            return self:parse_typename_from_type(type.pointeeType, template_types) .. ' *'
        end
    elseif kind == 'FunctionProto' then
        local exps = olua.newarray('')
        local result_type = self:parse_typename_from_type(type.resultType)
        exps:push(result_type)
        exps:push(result_type:find('[%*&]') and '' or ' ')
        exps:push('(')
        for i, v in ipairs(type.argTypes) do
            exps:push(i > 1 and ', ' or nil)
            exps:push(self:parse_typename_from_type(v))
        end
        exps:push(')')
        return tostring(exps)
    else
        --[[
            type.name:
                const ui::Button
            type.canonicalType.name:
                const cclua::ui::Button

            type.name:
                const ui::ClickListener
            type.canonicalType.name:
                const cclua::Object *(*ClickListener)()
            build_name:
                const cclua::ui::ClickListener
        ]]
        local rawtype = name
        local tokens = {const = '', struct = '', enum = '', union = ''}
        while true do
            local value, k = rawtype:match('^((%w+) )')
            if tokens[k] then
                tokens[k] = value
                rawtype = rawtype:sub(#value + 1)
            else
                break
            end
        end
        local cname = type.canonicalType.name:gsub('const ', '')
        local newname
        if template_types and template_types[name] then
            return '$@' .. name -- is template type
        end
        if not rawtype:find(':') then
            rawtype = '::' .. rawtype
        end
        if olua.is_end_with(cname, rawtype) then
            newname = cname
        else
            cname = self:parse_typename_from_tree(type)
            if olua.is_end_with(cname, rawtype) then
                newname = cname
            end
        end
        if newname then
            name = newname
            for _, k in ipairs({'enum', 'union', 'struct', 'const'}) do
                local v = tokens[k]
                if #v > 0 and not name:find(v) then
                    name = v .. name
                end
            end
        end
        return name
    end
end

function M:typename(type, template_types)
    local tn = self:parse_typename_from_type(type, template_types)
    local rawtn = tn:gsub('^const ', ''):match('[^ <]+')
    local alias = alias_types[rawtn]
    if alias and not type_convs[rawtn] then
        -- namespace::alias<K, V> => namespace::alias
        if olua.typeinfo(alias:gsub('<.+>', ''), nil, true) then
            -- rawtn: olua::ClickListener
            -- alias: std::function<void (Object *)>
            -- const olua::ClickListener & => const std::function<void (Object *)> &
            tn = string.gsub(tn, rawtn, alias)
        end
    end
    return tn
end

local DEFAULT_ARG_TYPES = {
    IntegerLiteral = true,
    FloatingLiteral = true,
    ImaginaryLiteral = true,
    StringLiteral = true,
    CharacterLiteral = true,
    CXXBoolLiteralExpr = true,
    CXXNullPtrLiteralExpr = true,
    GNUNullExpr = true,
    DeclRefExpr = true,
    CallExpr = true,
}

function M:has_default_value(cur)
    for _, c in ipairs(cur.children) do
        if DEFAULT_ARG_TYPES[c.kind] then
            return true
        elseif self:has_default_value(c) then
            return true
        end
    end
end

function M:has_unexposed_attr(cur)
    for _, c in ipairs(cur.children) do
        -- attribute(deprecated) ?
        if c.kind == 'UnexposedAttr' then
            return true
        end
    end
end

function M:has_exclude_attr(cur)
    for _, c in ipairs(cur.children) do
        if c.kind == 'AnnotateAttr' and c.name == '@exclude' then
            return true
        end
    end
end

function M:is_func_type(tn)
    local rawtn = tn:match('([%w:_]+) ?[&*]?$')
    local decl = alias_types[rawtn] or ''
    return tn:find('std::function') or decl:find('std::function')
end

function M:parse_attr_from_annotate(attr, cur, isvar)
    local function parse_and_merge_attr(node, key)
        local exps = nil
        for _, c in ipairs(node.children) do
            if c.kind == 'AnnotateAttr' then
                local name = c.name
                if name:find('^@') then
                    exps = exps or olua.newarray(' ')
                    exps:push(name)
                end
            end
        end
        if exps then
            exps:push(attr[key])
            attr[key] = tostring(exps)
        end
    end

    parse_and_merge_attr(cur, 'ret')
    if not isvar then
        for i, arg in ipairs(cur.arguments) do
            parse_and_merge_attr(arg, 'arg' .. i)
        end
    end
end

function M:get_attr_copy(cls, fn, wildcard)
    local attrs = (cls.maincls or cls).attrs
    return setmetatable({}, {__index = (attrs[fn] or attrs[wildcard or '*'] or {})})
end

function M:visit_method(cls, cur)
    if cur.isVariadic
        or cur.isCopyConstructor
        or cur.isMoveConstructor
        or cur.name:find('operator *[%-=+/*><!()]?')
        or cur.name == 'as'  -- 'as used to cast object'
        or self:is_excluded_type(cur.resultType)
        or self:has_unexposed_attr(cur)
        or self:has_exclude_attr(cur)
    then
        return
    end

    local fn = cur.name
    local luaname = fn
    local attr = self:get_attr_copy(cls, fn)
    local callback = cls.callbacks[fn] or {}
    local exps = olua.newarray('')
    local declexps = olua.newarray('')

    self:parse_attr_from_annotate(attr, cur)
    
    for i, arg in ipairs(cur.arguments) do
        local v = (attr['arg' .. i]) or ''
        if not v:find('@ret') and self:is_excluded_type(arg.type) then
            return
        end
    end

    exps:push(attr.ret and (attr.ret .. ' ') or nil)
    exps:push(cur.isStatic and 'static ' or nil)

    local cb_kind

    if cur.kind ~= 'Constructor' then
        local tn = self:typename(cur.resultType, cls.template_types)
        if self:is_func_type(tn) then
            cb_kind = 'ret'
            if callback.localvar ~= false then
                exps:push('@localvar ')
            end
        end
        local tn_decl = tn .. olua.typespace(tn)
        exps:push(tn_decl)
        declexps:push(tn_decl)
        luaname = cls.luaname(fn, 'func')
    end

    local optional = false
    local min_args = 0
    exps:push(fn .. '(')
    declexps:push(fn .. '(')
    for i, arg in ipairs(cur.arguments) do
        local tn = self:typename(arg.type, cls.template_types)
        local displayName = cur.displayName
        local argn = 'arg' .. i
        exps:push(i > 1 and ', ' or nil)
        declexps:push(i > 1 and ', ' or nil)
        declexps:push(tn)
        if self:is_func_type(tn) then
            if cb_kind then
                error(format('has more than one std::function: ${cls.cppcls}::${displayName}'))
            end
            assert(not cb_kind, cls.cppcls .. '::' .. displayName)
            cb_kind = 'arg'
            if callback.localvar ~= false then
                exps:push('@localvar ')
            end
        end
        if self:has_default_value(arg) and not string.find(attr[argn] or '', '@ret') then
            exps:push('@optional ')
            optional = true
        else
            min_args = min_args + 1
            assert(not optional, cls.cppcls .. '::' .. displayName)
        end
        exps:push(attr[argn] and (attr[argn] .. ' ') or nil)
        exps:push(tn)
        exps:push(olua.typespace(tn))
        exps:push(arg.name)
    end
    exps:push(')')
    declexps:push(')')

    local func = tostring(exps)
    local prototype =  tostring(declexps)
    cls.excludes:replace(cur.displayName, true)
    cls.excludes:replace(prototype, true)
    local static = cur.isStatic
    if cur.kind == 'FunctionDecl' then
        func = 'static ' .. func
        static = true
    end
    cls.funcs[prototype] = {
        func = func,
        luaname = luaname == fn and 'nil' or olua.stringify(luaname),
        name = fn,
        static = static,
        num_args = #cur.arguments,
        min_args = min_args,
        cb_kind = cb_kind,
        prototype = prototype,
        displayName = cur.displayName,
        isctor = cur.kind == 'Constructor',
    }
end

function M:visit_var(cls, cur)
    if cur.type.isConst or self:is_excluded_type(cur.type) then
        return
    end

    local exps = olua.newarray('')
    local attr = self:get_attr_copy(cls, cur.name, 'var*')
    local tn = self:typename(cur.type)
    local cb_kind

    if tn:find('%[') then
        return
    end

    self:parse_attr_from_annotate(attr, cur, true)

    if attr.readonly then
        exps:push('@readonly ')
    end

    local length = string.match(tn, '%[(%d+)%]$')
    if length then
        exps:pushf('@array(${length})')
        exps:push(' ')
        tn = string.gsub(tn, ' %[%d+%]$', '')
    elseif attr.optional or (self:has_default_value(cur) and attr.optional == nil) then
        exps:push('@optional ')
    end

    if self:is_func_type(tn) then
        cb_kind = 'var'
        exps:push('@nullable ')
        local callback = cls.callbacks:take(cur.name) or {}
        if callback.localvar ~= false then
            exps:push('@localvar ')
        end
    end

    exps:push(attr.ret and (attr.ret .. ' ') or nil)
    exps:push(cur.kind == 'VarDecl' and 'static ' or nil)
    exps:push(tn)
    exps:push(olua.typespace(tn))
    exps:push(cur.name)

    local decl = tostring(exps)
    local name = cls.luaname(cur.name, 'var')
    cls.vars[name] = {
        name = name,
        snippet = decl,
        cb_kind = cb_kind
    }
end

function M:do_visit(cppcls)
    local cls = self.class_types[cppcls]
    visited_types[cppcls] = cls
    ignored_types[cppcls] = false
    return cls
end

function M:visit_enum(cppcls, cur)
    local cls = self:do_visit(cppcls)
    for _, c in ipairs(cur.children) do
        local value =  c.name
        local name = cls.luaname(value, 'enum')
        cls.enums[name] = {
            name = name,
            value = format('${cls.cppcls}::${value}'),
        }
    end
    cls.indexerror = 'rw'
    cls.kind = cls.kind or kFLAG_ENUM
    alias_types[cls.cppcls] = nil
end

function M:visit_alias_class(alias, cppcls)
    local cls = self:do_visit(alias)
    cls.kind = cls.kind or kFLAG_POINTEE
    if self:is_func_type(cppcls) then
        cls.kind = cls.kind | kFLAG_FUNC
        cls.decltype = cppcls
        cls.luacls = self.luacls(alias)
    else
        cls.kind = cls.kind | kFLAG_ALIAS
        cls.supercls = cppcls
        cls.luacls = self.luacls(cppcls)
    end
end

function M:visit_class(cppcls, cur)
    local cls = self:do_visit(cppcls)
    local skipsuper = false

    cls.kind = cls.kind or kFLAG_POINTEE

    if cur.kind == 'ClassTemplate' then
        cls.kind = cls.kind | kFLAG_TEMPLATE
    end

    if cur.kind == 'StructDecl' then
        cls.kind = cls.kind | kFLAG_STRUCT
    end

    if cur.kind == 'Namespace' then
        cls.reg_luatype = false
    end

    for _, c in ipairs(cur.children) do
        local kind = c.kind
        local access = c.access
        if access == 'private' or access == 'protected' then
            if kind == 'FunctionDecl' or kind == 'CXXMethod' then
                cls.excludes:replace(c.displayName, true)
            end
            goto continue
        elseif kind == 'TemplateTypeParameter' then
            cls.template_types[c.name] = '$@' .. c.name
        elseif kind == 'CXXBaseSpecifier' then
            local supercls = self:typename(c.type)
            if self:is_excluded_typename(supercls)
                or self:is_excluded_typename(supercls .. ' *')
            then
                goto continue
            end

            if _G.OLUA_AUTO_EXPORT_PARENT then
                local rawsupercls = supercls:gsub('<.*>', '')
                local super = visited_types[rawsupercls]
                if not super then
                    self.CMD.typeconf(rawsupercls)
                    if is_templdate_type(supercls) then
                        self:visit_class(rawsupercls, template_cursors[rawsupercls])
                    end
                    self:visit_class(rawsupercls, c.type.declaration)
                    super = self.class_types:take(rawsupercls)
                    if super.supercls then
                        self.class_types:insert('after', visited_types[super.supercls], rawsupercls, super)
                    else
                        self.class_types:insert('front', nil, rawsupercls, super)
                    end
                end
            end

            if is_templdate_type(supercls) then
                local super = visited_types[supercls:gsub('<.*>', '')]
                skipsuper = true
                visited_types[supercls] = assert(super, supercls)
            end
            if not cls.supercls and not skipsuper then
                cls.supercls = supercls
            end
            cls.supers[supercls] = supercls
        elseif kind == 'UsingDeclaration' then
            for _, cc in ipairs(c.children) do
                if cc.kind == 'TypeRef' then
                    cls.usings[c.name] = cc.name:match('([^ ]+)$')
                    break
                end
            end
        elseif kind == 'FieldDecl' or kind == 'VarDecl' then
            local vn = c.name
            local ct = c.type
            local mode = #cls.includes > 0 and 'include' or 'exclude'
            if not _G.OLUA_ENABLE_WITH_UNDERSCORE
                and c.name:find('^_')
                and not metamethod[c.name]
            then
                goto continue
            end
            if (mode == 'include' and not cls.includes[vn])
                or (cls.excludes['*'] or cls.excludes[vn])
            then
                goto continue
            end
            if ct.isConst and kind == 'VarDecl' then
                if not self:is_excluded_type(ct) then
                    cls.consts[vn] = {name = vn, typename = ct.name}
                end
            else
                self:visit_var(cls, c)
            end
        elseif kind == 'Constructor' or kind == 'FunctionDecl' or kind == 'CXXMethod' then
            local mode = #cls.includes > 0 and 'include' or 'exclude'
            if not _G.OLUA_ENABLE_WITH_UNDERSCORE
                and c.name:find('^_')
                and not metamethod[c.name]
            then
                goto continue
            end
            if (mode == 'include' and not cls.includes[c.name])
                or (cls.excludes['*'] or cls.excludes[c.name] or cls.excludes[c.displayName])
                or (kind == 'Constructor' and (cls.excludes['new'] or cur.isAbstract))
            then
                goto continue
            end
            self:visit_method(cls, c)
        else
            self:visit(c)
        end

        ::continue::
    end
end

function M:visit(cur)
    local need_visit = false
    local kind = cur.kind
    local children = cur.children
    local cls = self:parse_typename_from_tree({declaration = cur, name = cur.name})
    if not self.class_types[cls] then
        for cppcls in pairs(self.wildcard_types) do
            if cls:find(cppcls) then
                self.CMD.typeconf(cls)
            end
        end
    end
    if kind == 'ClassTemplate' then
        -- TODO: will be removed next luaclang version
        template_cursors[cls] = cur
    end
    need_visit = self.class_types[cls] and not visited_types[cls]
    if self:has_unexposed_attr(cur) then
        return
    elseif #children == 0 or string.find(cls, "^std::") then
        return
    elseif kind == 'Namespace' then
        if need_visit then
            self:visit_class(cls, cur)
        else
            for _, c in ipairs(children) do
                self:visit(c)
            end
        end
    elseif kind == 'ClassTemplate' or kind == 'ClassDecl'
        or kind == 'StructDecl' or kind == 'UnionDecl'
    then
        if need_visit then
            self:visit_class(cls, cur)
        else
            if not exclude_types[cls] and ignored_types[cls] == nil then
                ignored_types[cls] = true
            end
            for _, c in ipairs(cur.children) do
                self:visit(c)
            end
        end
    elseif kind == 'EnumDecl' then
        if need_visit then
            self:visit_enum(cls, cur)
        end
    elseif kind == 'TypeAliasDecl' or kind == 'TypedefDecl' then
        local decl = cur.underlyingType.declaration
        local decl_kind = decl.kind
        if decl.kind == 'NoDeclFound' then
            return
        end
        local name = self:typename(cur.underlyingType)
        if name:find('^enum ') or name:find('^struct ')  then
            name = self:typename(decl.type)
        end
        local alias = ((decl_kind == 'EnumDecl' and 'enum ' or '') .. name)
        alias_types[cls] = alias_types[name] or alias
        if need_visit then
            if decl_kind == 'StructDecl' then
                self:visit_class(cls, decl)
            elseif decl_kind == 'EnumDecl' then
                self:visit_enum(cls, decl)
            elseif alias_types[cls]:find('^enum ') then
                if decl_kind == 'TypedefDecl' then
                    decl = decl.underlyingType.declaration
                end
                assert(decl.kind == 'EnumDecl', cls)
                self:visit_enum(cls, decl)
            else
                self:visit_alias_class(cls, alias_types[cls])
            end
        end
    else
        for _, c in ipairs(children) do
            self:visit(c)
        end
    end
end

-------------------------------------------------------------------------------
-- output config
-------------------------------------------------------------------------------
local function write_module_metadata(module, append)
    append(format([[
        name = "${module.name}"
        path = "${module.path}"
    ]]))

    append(format('headers = ${module.headers?}'))
    append(format('chunk = ${module.chunk?}'))
    append(format('luaopen = ${module.luaopen?}'))
    append('')

    for _, cls in ipairs(module.class_types) do
        if not has_kflag(cls, kFLAG_CONV) then
            goto continue
        end

        ignored_types[cls.cppcls] = false

        local macro = (cls.macros['*'] or {}).value
        append(format([[typeconv '${cls.cppcls}']]))
        append(format([[.export(${cls.export})]], 4))
        for _, v in ipairs(cls.macros) do
            append(format([[.macro('${v.name}', '${v.value}')]], 4))
        end
        for _, v in ipairs(cls.vars) do
            append(format('.var(${v.name?}, ${v.snippet?})', 4))
        end
        append('')

        ::continue::
    end
end

local function write_module_typedef(module)
    local t = olua.newarray('\n')

    local function writeLine(fmt, ...)
        t:push(string.format(fmt, ...))
    end

    writeLine("-- AUTO BUILD, DON'T MODIFY!")
    writeLine('')
    for _, td in ipairs(module.typedef_types) do
        local arr = {}
        ignored_types[td.cppcls] = false
        for k, v in pairs(td) do
            arr[#arr + 1] = {k, v}
        end
        table.sort(arr, function (a, b) return a[1] < b[1] end)
        writeLine("typedef {")
        for _, p in ipairs(arr) do
            local key, value = p[1], p[2]
            writeLine(format('${key} = ${value?},', 4))
        end
        writeLine("}")
        writeLine("")
    end

    for _, cls in ipairs(module.class_types) do
        if cls.maincls then
            goto continue
        end

        local conv
        local cppcls = cls.cppcls
        local supercls =  'nil'
        local decltype, luacls, num_vars = 'nil', 'nil', 'nil'

        if cls.supercls then
            supercls = olua.stringify(cls.supercls, "'")
        end
        if has_kflag(cls, kFLAG_FUNC) then
            luacls = olua.stringify(cls.luacls, "'")
            decltype = olua.stringify(cls.decltype, "'")
            conv = 'olua_$$_callback'
        elseif has_kflag(cls, kFLAG_ENUM) then
            conv = 'olua_$$_uint'
            luacls = olua.stringify(cls.luacls, "'")
            decltype = olua.stringify('lua_Unsigned')
        elseif has_kflag(cls, kFLAG_POINTEE) then
            if has_kflag(cls, kFLAG_STRUCT) then
                cppcls = format('${cppcls} *; struct ${cppcls} *')
            else
                cppcls = cppcls .. ' *'
            end
            luacls = olua.stringify(cls.luacls, "'")
            conv = 'olua_$$_cppobj'
        elseif has_kflag(cls, kFLAG_CONV) then
            conv = 'olua_$$_' .. string.gsub(cls.cppcls, '[.:]+', '_')
            num_vars = #cls.vars
        else
            error(cls.cppcls .. ' ' .. cls.kind)
        end

        t:pushf([[
            typedef {
                cppcls = '${cppcls}',
                luacls = ${luacls},
                supercls = ${supercls},
                decltype = ${decltype},
                conv = '${conv}',
                num_vars = ${num_vars},
            }
        ]])

        if has_kflag(cls, kFLAG_POINTEE) and has_kflag(cls, kFLAG_CONV) then
            cppcls = cppcls:gsub('[ *]+', '')
            luacls = 'nil'
            conv = 'olua_$$_' .. string.gsub(cls.cppcls, '[.:]+', '_')
            num_vars =  #cls.vars
            t:pushf([[
                typedef {
                    cppcls = '${cppcls}',
                    luacls = ${luacls},
                    supercls = ${supercls},
                    decltype = ${decltype},
                    conv = '${conv}',
                    num_vars = ${num_vars},
                }
            ]])
        end

        ::continue::
    end

    olua.write(module.type_file, tostring(t))
end

local function is_new_func(module, supercls, fn)
    if not supercls or fn.static then
        return true
    end

    local super = visited_types[supercls]
    if not super then
        error(format("not found super class '${supercls}'"))
    elseif super.funcs[fn.prototype] or super.excludes[fn.name] then
        return false
    else
        return is_new_func(module, super.supercls, fn)
    end
end

local function parse_prop_name(fn)
    if (fn.name:find('^[gG]et') or fn.name:find('^[iI]s'))
        and (fn.num_args == 0 or (fn.extended and fn.num_args == 1))
    then
        -- getABCd isAbc => ABCd Abc
        local name
        if fn.name:find('^[gG]et') then
            name = fn.name:gsub('^[gG]et', '')
        else
            name = fn.name:gsub('^[iI]s', '')
        end
        return string.gsub(name, '^%u+', function (str)
            if #str > 1 and #str ~= #name then
                if #str == #name - 1 then
                    -- ABCDs => abcds
                    return str:lower()
                else
                    -- ABCd => abCd
                    return str:sub(1, #str - 1):lower() .. str:sub(#str)
                end
            else
                -- AbcdEF => abcdEF
                return str:lower()
            end
        end)
    end
end

local function search_using_func(module, cls)
    local function search_parent(arr, name, supercls)
        local super = visited_types[supercls]
        if super then
            for _, fn in ipairs(super.funcs) do
                if fn.name == name then
                    arr[#arr + 1] = fn
                end
            end
            if #arr == 0 then
                search_parent(arr, name, super.supercls)
            end
        end
    end
    for name, where in pairs(cls.usings) do
        local arr = {}
        local supercls = cls.supercls
        while supercls and supercls ~= where do
            local super = visited_types[supercls]
            if super then
                supercls = super.supercls
            end
        end
        search_parent(arr, name, supercls)
        for _, fn in ipairs(arr) do
            if not cls.funcs[fn.prototype] then
                cls.funcs[fn.prototype] = fn
            end
        end
    end
end

local function write_cls_func(module, cls, append)
    search_using_func(module, cls)

    local group_by_name = olua.newhash()
    for _, fn in ipairs(cls.funcs) do
        local arr = group_by_name[fn.name]
        if not arr then
            arr = {}
            group_by_name[fn.name] = arr
        end
        if fn.snippet or is_new_func(module, cls.supercls, fn) then
            arr.has_new = true
        else
            fn = setmetatable({
                func = '@using ' .. fn.func
            }, {__index = fn})
        end
        arr[#arr + 1] = fn
    end

    for _, arr in ipairs(group_by_name) do
        if not arr.has_new then
            goto continue
        end
        local funcs = olua.newarray("', '", "'", "'")
        local has_callback = false
        local fi = arr[1]
        for _, v in ipairs(arr) do
            if v.cb_kind or cls.callbacks[v.name] then
                has_callback = true
            end
            funcs[#funcs + 1] = v.func
        end

        if #arr == 1 and _G.OLUA_AUTO_GEN_PROP then
            local name = parse_prop_name(fi)
            if name then
                local setname = 'set' .. name:lower()
                local lessone, moreone
                for _, f in ipairs(cls.funcs) do
                    if f.name:lower() == setname then
                        if f.min_args <= (f.extended and 2 or 1) then
                            lessone = true
                        end
                        if f.min_args > (f.extended and 2 or 1) then
                            moreone = true
                        end
                    end
                end
                if lessone or not moreone then
                    cls.props:replace(name, {name = name})
                end
            end
        end
        if not has_callback then
            if #funcs > 0 then
                append(format(".func(${fi.luaname}, ${funcs})", 4))
            else
                append(format(".func('${fi.name}', ${fi.snippet?})", 4))
            end
        else
            local tag_maker = fi.name:gsub('^set', ''):gsub('^get', '')
            local mode = fi.cb_kind == 'ret' and 'equal' or 'replace'
            local callback = cls.callbacks[fi.name]
            if callback then
                callback.funcs = funcs
                callback.tag_maker = callback.tag_maker or format('${tag_maker}')
                callback.tag_mode = callback.tag_mode or mode
            else
                cls.callbacks[fi.name] = {
                    name = fi.name,
                    funcs = funcs,
                    tag_maker = olua.format '${tag_maker}',
                    tag_mode = mode,
                }
            end
        end

        ::continue::
    end

     -- find as
     local ascls = olua.newhash()
     if #cls.supers > 1 then
        local function find_as_cls(c)
            for supercls in pairs(c.supers) do
                ascls:replace(supercls, supercls)
                find_as_cls(visited_types[supercls])
            end
        end
        find_as_cls(cls)

        -- remove first super class
        local function remove_first_as_cls(c)
            local supercls = c.supercls
            if supercls then
                ascls:take(supercls)
                remove_first_as_cls(visited_types[supercls])
            end
        end
        remove_first_as_cls(cls)
     end
     if #ascls > 0 then
        table.sort(ascls.values)
        local func = table.concat(ascls.values, ' ')
        func = format("'@as(${func}) void *as(const char *cls)'")
        append(format(".func(nil, ${func})", 4))
     end
end

local function write_cls_macro(module, cls, append)
    for _, v in ipairs(cls.macros) do
        append(format([[.macro('${v.name}', '${v.value}')]], 4))
    end
end

local function write_cls_const(module, cls, append)
    for _, v in ipairs(cls.consts) do
        append(format([[.const('${v.name}', '${cls.cppcls}::${v.name}', '${v.typename}')]], 4))
    end
end

local function write_cls_enum(module, cls, append)
    for _, e in ipairs(cls.enums) do
        append(format(".enum('${e.name}', '${e.value}')", 4))
    end
end

local function write_cls_var(module, cls, append)
    for _, fn in ipairs(cls.vars) do
        append(format(".var('${fn.name}', ${fn.snippet?})", 4))
    end
end

local function write_cls_prop(module, cls, append)
    for _, p in ipairs(cls.props) do
        append(format([[.prop('${p.name}', ${p.get?}, ${p.set?})]], 4))
    end
end

local function write_cls_callback(module, cls, append)
    for i, v in ipairs(cls.callbacks) do
        assert(v.funcs, cls.cppcls .. '::' .. v.name)
        local funcs = olua.newarray("',\n'", "'", "'"):merge(v.funcs)
        local tag_maker = olua.newarray("', '", "'", "'")
        local tag_mode = olua.newarray("', '", "'", "'")
        local tag_store = v.tag_store or '0'
        local tag_scope = v.tag_scope or 'object'
        if type(v.tag_store) == 'string' then
            tag_store = olua.stringify(v.tag_store)
        end
        assert(v.tag_maker, 'no tag maker')
        assert(v.tag_mode, 'no tag mode')
        if type(v.tag_maker) == 'string' then
            tag_maker:push(v.tag_maker)
        else
            tag_maker:merge(v.tag_maker)
            tag_maker = format('{${tag_maker}}')
        end
        if type(v.tag_mode) == 'string' then
            tag_mode:push(v.tag_mode)
        else
            tag_mode:merge(v.tag_mode)
            tag_mode = format('{${tag_mode}}')
        end
        append(format([[
            .callback {
                funcs =  {
                    ${funcs}
                },
                tag_maker = ${tag_maker},
                tag_mode = ${tag_mode},
                tag_store = ${tag_store},
                tag_scope = '${tag_scope}',
            }
        ]], 4))
        log(format([[
            funcs => name = '${v.name}'
                    funcs = {
                        ${funcs}
                    }
                    tag_maker = ${tag_maker}
                    tag_mode = ${tag_mode}
                    tag_store = ${tag_store}
                    tag_scope = ${tag_scope}
        ]], 4))
    end
end

local function write_cls_insert(module, cls, append)
    for _, v in ipairs(cls.inserts) do
        if v.before or v.after or v.cbefore or v.cafter then
            append(format([[
                .insert('${v.name}', {
                    before = ${v.before?},
                    after = ${v.after?},
                    cbefore = ${v.cbefore?},
                    cafter = ${v.cafter?},
                })
            ]], 4))
        end
    end
end

local function write_cls_alias(module, cls, append)
    for _, v in ipairs(cls.aliases) do
        append(format(".alias('${v.name}', '${v.alias}')", 4))
    end
end

local function copy_super_template_funcs(cls, super, supercls)
    for _, v in ipairs(super.funcs) do
        local fn = setmetatable({}, {__index = v})
        for _, t in ipairs(super.template_types) do
            local old = t .. ' '
            local new = cls.cppcls .. ' '
            fn.func = fn.func:gsub(old, new)
            fn.prototype = fn.prototype:gsub(old, new)
        end
        if not cls.funcs[fn.prototype]
            and not fn.isctor
            and not cls.excludes[fn.displayName]
            and not fn.snippet
        then
            cls.funcs[fn.prototype] = setmetatable({
                func = format("@copyfrom(${super.cppcls}) ${fn.func}")
            }, {__index = fn})
        end
    end
    for sc in pairs(super.supers) do
        copy_super_template_funcs(cls, visited_types[sc], sc)
    end
end

local function copy_super_funcs(cls, super)
    for _, fn in ipairs(super.funcs) do
        if not cls.funcs[fn.prototype]
            and not fn.isctor
            and not cls.excludes[fn.displayName]
            and not fn.snippet
        then
            cls.funcs[fn.prototype] = setmetatable({
                func = format("@copyfrom(${super.cppcls}) ${fn.func}")
            }, {__index = fn})
        end
    end
    for sc in pairs(super.supers) do
        copy_super_funcs(cls, visited_types[sc])
    end
end

local function copy_super_var(cls, super)
    for _, var in ipairs(super.vars) do
        if not cls.vars[var.name]
            and not cls.excludes[var.name]
        then
            cls.vars[var.name] = setmetatable({
                snippet = format("@copyfrom(${super.cppcls}) ${var.snippet}")
            }, {__index = var})
        end
    end
    for sc in pairs(super.supers) do
        copy_super_var(cls, visited_types[sc])
    end
end

local function write_module_classes(module, append)
    append('')
    for _, cls in ipairs(module.class_types) do
        for v in pairs(cls.extends) do
            local extcls = module.class_types[v]
            for _, fn in ipairs(extcls.funcs) do
                if not fn.static then
                    error(string.format('extend only support static function: %s::%s',
                        extcls.cppcls, fn.prototype))
                end
                fn.extended = true
                fn.func = format("@extend(${extcls.cppcls}) ${fn.func}")
                cls.funcs:replace(fn.prototype, fn)
            end
        end
    end
    for _, cls in ipairs(module.class_types) do
        for supercls in pairs(cls.supers) do
            if cls.supercls == supercls then
                goto continue
            end
            if is_templdate_type(supercls) then
                copy_super_template_funcs(cls, visited_types[supercls], supercls)
            else
                copy_super_funcs(cls, visited_types[supercls])
                copy_super_var(cls, visited_types[supercls])
            end
            ::continue::
        end
    end
    for _, cls in ipairs(module.class_types) do
        if (has_kflag(cls, kFLAG_CONV) and not has_kflag(cls, kFLAG_POINTEE))
            or has_kflag(cls, kFLAG_ALIAS)
            or has_kflag(cls, kFLAG_TEMPLATE) -- don't export template class
            or cls.maincls
        then
            goto continue
        end

        log("[%s]", cls.cppcls)
        append(format([[
            typeconf '${cls.cppcls}'
                .supercls(${cls.supercls?})
                .reg_luatype(${cls.reg_luatype?})
                .chunk(${cls.chunk?})
                .luaopen(${cls.luaopen?})
                .indexerror(${cls.indexerror?})
        ]]))

        write_cls_macro(module, cls, append)
        write_cls_const(module, cls, append)
        write_cls_func(module, cls, append)
        write_cls_enum(module, cls, append)
        write_cls_var(module, cls, append)
        write_cls_callback(module, cls, append)
        write_cls_prop(module, cls, append)
        write_cls_insert(module, cls, append)
        write_cls_alias(module, cls, append)

        append('')

        ::continue::
    end
end

local function write_module(module)
    local t = olua.newarray('\n')

    local function append(str)
        t:push(str)
    end

    append(format([[
        -- AUTO BUILD, DON'T MODIFY!

        dofile "${module.type_file}"
    ]]))
    append('')

    write_module_metadata(module, append)
    write_module_classes(module, append)
    write_module_typedef(module, append)

    olua.write(module.class_file, tostring(t))
end

local function parse_modules()
    local headers = olua.newarray('\n')
    for _, m in ipairs(deferred.modules) do
        headers:push(m.headers)
    end

    do
        local HEADER_PATH = 'autobuild/.autoconf.h'
        local header = io.open(HEADER_PATH, 'w')
        header:write(format [[
            #ifndef __AUTOCONF_H__
            #define __AUTOCONF_H__

            ${headers}

            #endif
        ]])
        header:close()
        local has_target = false
        local has_stdv = false
        local flags = olua.newarray()
        flags:push('-DOLUA_AUTOCONF')
        for i, v in ipairs(deferred.clang_args) do
            flags[#flags + 1] = v
            if v:find('^-target') then
                has_target = true
            end
            if v:find('^-std') then
                has_stdv = true
            end
        end
        if not has_stdv then
            flags:push('-std=c++11')
        end
        if not has_target then
            flags:merge({
                '-x', 'c++', '-nostdinc',
                '-U__SSE__',
                '-DANDROID',
                '-target', 'armv7-none-linux-androideabi',
                '-idirafter', '${OLUA_HOME}/include/c++',
                '-idirafter', '${OLUA_HOME}/include/c',
                '-idirafter', '${OLUA_HOME}/include/android-sysroot/x86_64-linux-android',
                '-idirafter', '${OLUA_HOME}/include/android-sysroot',
            })
        end
        for i, v in ipairs(flags) do
            local OLUA_HOME = olua.OLUA_HOME
            flags[i] = format(v)
        end
        clang_tu = clang.createIndex(false, true):parse(HEADER_PATH, flags)
        for _, v in ipairs(clang_tu:diagnostics()) do
            if v.severity == 'error' or v.severity == 'fatal' then
                error('parse header error')
            end
        end
        os.remove(HEADER_PATH)
    end

    for _, m in ipairs(deferred.modules) do
        for _, cls in ipairs(m.class_types) do
            for fn, fi in pairs(cls.funcs) do
                if not fi.snippet then
                    cls.funcs:take(fn)
                    cls.excludes:take(fn)
                end
            end
            for vn, vi in pairs(cls.vars) do
                if not vi.snippet then
                    cls.vars:take(vn)
                    cls.excludes:take(vn)
                end
            end
        end
        setmetatable(m, {__index = M})
        m:parse()
        write_module(m)
    end
end

local function write_ignored_types()
    local file = io.open('autobuild/autoconf-ignore.log', 'w')
    local arr = {}
    for cls, flag in pairs(ignored_types) do
        if flag then
            arr[#arr + 1] = cls
        end
    end
    table.sort(arr)
    for _, cls in pairs(arr) do
        file:write(string.format("[ignore class] %s\n", cls))
    end
end

local function write_alias_types()
    local types = olua.newarray('\n')
    for cppcls, v in pairs(alias_types) do
        if visited_types[cppcls] then
            goto continue
        end
        if v:find('^enum ') then
            types:push({
                cppcls = cppcls,
                decltype = 'lua_Unsigned',
                conv = 'olua_$$_uint',
            })
        elseif type(type_convs[v]) == 'string' then
            types:push({
                cppcls = cppcls,
                decltype = cppcls,
                conv = type_convs[v],
            })
        end
        ::continue::
    end
    local typedefs = olua.newarray('\n')
    for i, v in ipairs(olua.sort(types, 'cppcls')) do
        typedefs:pushf([[
            typedef {
                cppcls = '${v.cppcls}',
                decltype = '${v.decltype}',
                conv = '${v.conv}',
            }
        ]])
        typedefs:push('')
    end

    olua.write('autobuild/alias-types.lua', format([[
        ${typedefs}
    ]]))
end

local function write_makefile()
    local class_files = olua.newarray('\n')
    local type_files = olua.newarray('\n')
    type_files:push('dofile "autobuild/alias-types.lua"')
    for _, v in ipairs(module_files) do
        class_files:pushf('export "${v.class_file}"')
        type_files:pushf('dofile "${v.type_file}"')
    end
    olua.write('autobuild/make.lua', format([[
        require "olua.tools"

        ${type_files}

        ${class_files}
    ]]))
end

local function deferred_autoconf()
    parse_modules()
    write_ignored_types()
    write_alias_types()
    write_makefile()

    template_cursors = nil
    exclude_types = nil
    ignored_types = nil
    visited_types = nil
    alias_types = nil
    type_convs = nil
    module_files = nil
    deferred = nil

    if _G.OLUA_AUTO_BUILD ~= false then
        dofile('autobuild/make.lua')
    end
end

-------------------------------------------------------------------------------
-- define config module
-------------------------------------------------------------------------------
local function checkstr(key, v)
    if type(v) ~= 'string' then
        error(string.format("command '%s' expect 'string', got '%s'", key, type(v)))
    end
    return v
end

local function tonum(key, v)
    return tonumber(v)
end

local function checkfunc(key, v)
    if type(v) ~= 'function' then
        error(string.format("command '%s' expect 'function', got '%s'", key, type(v)))
    end
    return v
end

local function totable(key, v)
    return type(v) == 'table' and v or nil
end

local function tobool(key, v)
    if v == 'true' then
        return true
    elseif v == 'false' then
        return false
    end
end

local function toany(...)
    local funcs = {...}
    return function (key, ...)
        for _, f in ipairs(funcs) do
            local v = f(key, ...)
            if v ~= nil then
                return v
            end
        end
        return checkstr(key, ...)
    end
end

local function add_value_command(CMD, key, store, field, tofunc)
    tofunc = tofunc or checkstr
    field = field or key
    CMD[key] = function (v)
        store[field] = tofunc(key, v)
    end
end

local function add_attr_command(CMD, name, cls)
    local entry = {}
    cls.attrs[name] = entry
    add_value_command(CMD, 'optional', entry, nil, tobool)
    add_value_command(CMD, 'readonly', entry, nil, tobool)
    add_value_command(CMD, 'ret', entry)
    for i = 1, 25 do
        add_value_command(CMD, 'arg' .. i, entry)
    end
end

local function add_insert_command(CMD, name, cls)
    local entry = {name = name}
    cls.inserts[name] = entry
    add_value_command(CMD, 'insert_before', entry, 'before')
    add_value_command(CMD, 'insert_after', entry, 'after')
    add_value_command(CMD, 'insert_cbefore', entry, 'cbefore')
    add_value_command(CMD, 'insert_cafter', entry, 'cafter')
end

local function make_typeconf_command(cls, ModuleCMD)
    local CMD = {}
    local macro = nil
    local mode = nil

    add_value_command(CMD, 'chunk', cls)
    add_value_command(CMD, 'luaname', cls, nil, checkfunc)
    add_value_command(CMD, 'supercls', cls)
    add_value_command(CMD, 'luaopen', cls)
    add_value_command(CMD, 'indexerror', cls)
    add_value_command(CMD, '_maincls', cls, "maincls", totable)

    if has_kflag(cls, kFLAG_CONV) then
        cls.export = false
        add_value_command(CMD, 'export', cls, nil, tobool)
    end

    function CMD.extend(extcls)
        cls.extends[extcls] = true
        ModuleCMD.typeconf(extcls)
            ._maincls(cls)
    end

    function CMD.exclude(name)
        if mode and mode ~= 'exclude' then
            error(string.format(
                "can't use .include and .exclude at the same time in typeconf '%s'",
                cls.cppcls
            ))
        end
        mode = 'exclude'
        name = checkstr('exclude', name)
        cls.excludes[name] = true
    end

    function CMD.include(name)
        if mode and mode ~= 'include' then
            error(string.format(
                "can't use .include and .exclude at the same time in typeconf '%s'",
                cls.cppcls
            ))
        end
        mode = 'include'
        name = checkstr('include', name)
        cls.includes[name] = true
    end

    function CMD.macro(cond)
        cond = checkstr('macro', cond)
        if cond == '' then
            macro = nil
        else
            macro = cond
        end
    end

    function CMD.enum(name)
        local entry = {name = name}
        local SubCMD = {}
        name = checkstr('enum', name)
        cls.enums[name] = entry
        add_value_command(SubCMD, 'value', entry)
        return olua.command_proxy(SubCMD, CMD)
    end

    function CMD.const(name)
        local entry = {name = name}
        local SubCMD = {}
        name = checkstr('const', name)
        cls.consts[name] = entry
        add_value_command(SubCMD, 'value', entry)
        add_value_command(SubCMD, 'typename', entry)
        return olua.command_proxy(SubCMD, CMD)
    end

    function CMD.func(name)
        local entry = {name = name}
        local SubCMD = {}
        name = checkstr('func', name)
        cls.excludes[name] = true
        if macro then
            cls.macros[name] = {name = name, value = macro}
        end
        cls.funcs[name] = entry
        add_value_command(SubCMD, 'snippet', entry)
        add_attr_command(SubCMD, name, cls)
        add_insert_command(SubCMD, name, cls)
        return olua.command_proxy(SubCMD, CMD)
    end

    function CMD.callback(name)
        local entry = {name = name}
        local SubCMD = {}
        name = checkstr('callback', name)
        cls.callbacks[name] = entry
        add_value_command(SubCMD, 'localvar', entry, nil, tobool)
        add_value_command(SubCMD, 'tag_maker', entry, nil, toany(totable))
        add_value_command(SubCMD, 'tag_mode', entry, nil, toany(totable))
        add_value_command(SubCMD, 'tag_store', entry, nil, tonum)
        add_value_command(SubCMD, 'tag_scope', entry, nil)
        add_attr_command(SubCMD, name, cls)
        add_insert_command(SubCMD, name, cls)
        return olua.command_proxy(SubCMD, CMD)
    end

    function CMD.prop(name)
        local entry = {name = name}
        local SubCMD = {}
        name = checkstr('prop', name)
        cls.props[name] = entry
        add_value_command(SubCMD, 'get', entry)
        add_value_command(SubCMD, 'set', entry)
        return olua.command_proxy(SubCMD, CMD)
    end

    function CMD.var(name, snippet)
        local entry = {name = name}
        local SubCMD = {}
        name = checkstr('var', name)
        if name ~= '*' then
            cls.excludes[name] = true
            cls.vars[name] = entry
            add_value_command(SubCMD, 'snippet', entry)
        else
            name = 'var*'
        end
        add_attr_command(SubCMD, name, cls)
        return olua.command_proxy(SubCMD, CMD)
    end

    function CMD.alias(value)
        local name, alias = string.match(value, '([^ ]+) *-> *([^ ]+)')
        assert(name, value)
        cls.aliases[name] = {name = name, alias = alias}
    end

    return olua.command_proxy(CMD)
end

local function make_typedef_command(cls)
    local CMD = {}
    add_value_command(CMD, 'vars', cls, 'num_vars', tonum)
    add_value_command(CMD, 'decltype', cls)
    add_value_command(CMD, 'conv', cls)
    return olua.command_proxy(CMD)
end

--
-- module conf
-- autoconf 'conf/lua-exmpale.lua'
--
local has_hook = false

function M.__call(_, path)
    if not has_hook then
        has_hook = true
        local debug_getinfo = debug.getinfo
        local build_func = debug_getinfo(2, "f").func
        local count = 0
        debug.sethook(function ()
            count = count + 1
            if debug_getinfo(2, "f").func == build_func then
                debug.sethook(nil)
                deferred_autoconf()
            end
        end, 'r')
    end

    local macro = nil
    local CMD = {}
    local module = {
        CMD = CMD,
        headers = '',
        class_types = olua.newhash(),
        wildcard_types = olua.newhash(),
        typedef_types = olua.newhash(),
        luacls = function (cppname)
            return string.gsub(cppname, "::", ".")
        end,
    }

    add_value_command(CMD, 'module', module, 'name')
    add_value_command(CMD, 'path', module)
    add_value_command(CMD, 'luaopen', module)
    add_value_command(CMD, 'headers', module)
    add_value_command(CMD, 'chunk', module)
    add_value_command(CMD, 'luacls', module, nil, checkfunc)

    function CMD.exclude(tn)
        tn = olua.pretty_typename(tn)
        exclude_types[tn] = true
    end

    function CMD.include(filepath)
        assert(loadfile(filepath, nil, CMD))()
    end

    function CMD.macro(cond)
        cond = checkstr('macro', cond)
        if cond == '' then
            macro = nil
        else
            macro = cond
        end
    end

    function CMD.typeconf(classname, kind)
        local cls = {
            cppcls = assert(classname, 'not specify classname'),
            luacls = module.luacls(classname),
            extends = olua.newhash(),
            excludes = olua.newhash(),
            includes = olua.newhash(),
            usings = olua.newhash(),
            attrs = olua.newhash(),
            enums = olua.newhash(),
            consts = olua.newhash(),
            funcs = olua.newhash(),
            callbacks = olua.newhash(),
            props = olua.newhash(),
            vars = olua.newhash(),
            aliases = olua.newhash(),
            inserts = olua.newhash(),
            macros = olua.newhash(),
            index = #module.class_types + 1,
            kind = kind,
            supers = olua.newhash(),
            reg_luatype = true,
            template_types = olua.newhash(),
            luaname = function (n) return n end,
        }
        local last = module.class_types[classname]
        if last then
            if last.kind == kind then
                assert(not module.class_types[classname], 'class conflict: ' .. classname)
            else
                if kind == kFLAG_CONV then
                    cls = last
                end
                if not cls.kind then
                    cls.kind = kFLAG_POINTEE
                end
                cls.kind = cls.kind | kFLAG_CONV
                module.class_types:take(classname)
            end
        end
        if classname:find('[%^%%%$%*%+]') then -- ^%$*+
            module.wildcard_types[classname] = cls
        else
            module.class_types[classname] = cls
        end
        if macro then
            cls.macros['*'] = {name = '*', value = macro}
        end
        return make_typeconf_command(cls, CMD)
    end

    function CMD.typeonly(classname)
        local cls = CMD.typeconf(classname)
        cls.exclude '*'
        return cls
    end

    function CMD.typedef(classname)
        local cls = {cppcls = classname}
        module.typedef_types[classname] = cls
        return make_typedef_command(cls)
    end

    function CMD.typeconv(classname)
        return CMD.typeconf(classname, kFLAG_CONV)
    end

    function CMD.clang(clang_args)
        deferred.clang_args = clang_args
        module = nil
    end

    assert(loadfile(path, nil, setmetatable({}, {
        __index = function (_, k)
            return CMD[k] or _ENV[k]
        end,
        __newindex = function (_, k)
            error(string.format("create command '%s' is not available", k))
        end
    })))()

    if module and module.name then
        deferred.modules:push(module)
    end
end

olua.autoconf = setmetatable({}, M)
