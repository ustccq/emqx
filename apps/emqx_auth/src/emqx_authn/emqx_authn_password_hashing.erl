%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_authn_password_hashing).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-type simple_algorithm_name() :: plain | md5 | sha | sha256 | sha512.
-type salt_position() :: disable | prefix | suffix.

-type simple_algorithm() :: #{
    name := simple_algorithm_name(),
    salt_position := salt_position()
}.

-type bcrypt_algorithm() :: #{name := bcrypt}.
-type bcrypt_algorithm_rw() :: #{name := bcrypt, salt_rounds := integer()}.

-type pbkdf2_algorithm() :: #{
    name := pbkdf2,
    mac_fun := emqx_passwd:pbkdf2_mac_fun(),
    iterations := pos_integer()
}.

-type algorithm() :: simple_algorithm() | pbkdf2_algorithm() | bcrypt_algorithm().
-type algorithm_rw() :: simple_algorithm() | pbkdf2_algorithm() | bcrypt_algorithm_rw().

%%------------------------------------------------------------------------------
%% Hocon Schema
%%------------------------------------------------------------------------------

-behaviour(hocon_schema).

-export([
    roots/0,
    fields/1,
    desc/1,
    namespace/0
]).

-export([
    type_ro/1,
    type_rw/1,
    type_rw_api/1
]).

-export([
    init/1,
    gen_salt/1,
    hash/2,
    check_password/4
]).

-define(SALT_ROUNDS_MIN, 5).
-define(SALT_ROUNDS_MAX, 10).

namespace() -> "authn_hash".
roots() -> [pbkdf2, bcrypt, bcrypt_rw, bcrypt_rw_api, simple].

fields(bcrypt_rw) ->
    fields(bcrypt) ++
        [
            {salt_rounds, fun bcrypt_salt_rounds/1}
        ];
fields(bcrypt_rw_api) ->
    fields(bcrypt) ++
        [
            {salt_rounds, fun bcrypt_salt_rounds_api/1}
        ];
fields(bcrypt) ->
    [{name, sc(bcrypt, #{required => true, desc => ?DESC("bcrypt_name")})}];
fields(pbkdf2) ->
    [
        {name,
            sc(
                pbkdf2, #{
                    required => true,
                    desc => ?DESC("pbkdf2_name")
                }
            )},
        {mac_fun,
            sc(
                hoconsc:enum([md4, md5, ripemd160, sha, sha224, sha256, sha384, sha512]),
                #{
                    required => true,
                    desc => ?DESC("pbkdf2_mac_fun")
                }
            )},
        {iterations,
            sc(
                pos_integer(),
                #{required => true, desc => ?DESC("pbkdf2_iterations")}
            )},
        {dk_length, fun dk_length/1}
    ];
fields(simple) ->
    [
        {name,
            sc(
                hoconsc:enum([plain, md5, sha, sha256, sha512]),
                #{required => true, desc => ?DESC("simple")}
            )},
        {salt_position, fun salt_position/1}
    ].

bcrypt_salt_rounds(converter) -> fun salt_rounds_converter/2;
bcrypt_salt_rounds(Option) -> bcrypt_salt_rounds_api(Option).

bcrypt_salt_rounds_api(type) -> range(?SALT_ROUNDS_MIN, ?SALT_ROUNDS_MAX);
bcrypt_salt_rounds_api(default) -> ?SALT_ROUNDS_MAX;
bcrypt_salt_rounds_api(example) -> ?SALT_ROUNDS_MAX;
bcrypt_salt_rounds_api(desc) -> ?DESC("bcrypt_salt_rounds");
bcrypt_salt_rounds_api(_) -> undefined.

salt_rounds_converter(undefined, _) ->
    undefined;
salt_rounds_converter(I, _) when is_integer(I) ->
    emqx_utils:clamp(I, ?SALT_ROUNDS_MIN, ?SALT_ROUNDS_MAX);
salt_rounds_converter(X, _) ->
    X.

desc(bcrypt_rw) ->
    ?DESC("bcrypt_rw");
desc(bcrypt_rw_api) ->
    desc("bcrypt_rw");
desc(bcrypt) ->
    ?DESC("bcrypt");
desc(pbkdf2) ->
    ?DESC("pbkdf2");
desc(simple) ->
    ?DESC("simple");
desc(_) ->
    undefined.

salt_position(type) -> {enum, [disable, prefix, suffix]};
salt_position(default) -> prefix;
salt_position(desc) -> ?DESC("salt_position");
salt_position(_) -> undefined.

dk_length(type) ->
    pos_integer();
dk_length(required) ->
    false;
dk_length(desc) ->
    ?DESC("dk_length");
dk_length(_) ->
    undefined.

%% for emqx_authn_mnesia
type_rw(type) ->
    hoconsc:union(rw_refs());
type_rw(desc) ->
    ?DESC("type_rw");
type_rw(Option) ->
    type_ro(Option).

%% for emqx_authn_mnesia API
type_rw_api(type) ->
    hoconsc:union(api_refs());
type_rw_api(desc) ->
    ?DESC("type_rw");
type_rw_api(_) ->
    undefined.

%% for other authn resources
type_ro(type) ->
    hoconsc:union(ro_refs());
type_ro(default) ->
    #{<<"name">> => sha256, <<"salt_position">> => prefix};
type_ro(desc) ->
    ?DESC("type_ro");
type_ro(_) ->
    undefined.

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

-spec init(algorithm()) -> ok.
init(#{name := bcrypt}) ->
    {ok, _} = application:ensure_all_started(bcrypt),
    ok;
init(#{name := _Other}) ->
    ok.

-spec gen_salt(algorithm_rw()) -> emqx_passwd:salt().
gen_salt(#{name := plain}) ->
    <<>>;
gen_salt(#{
    name := bcrypt,
    salt_rounds := Rounds
}) ->
    {ok, Salt} = bcrypt:gen_salt(Rounds),
    list_to_binary(Salt);
gen_salt(#{name := Other}) when Other =/= plain, Other =/= bcrypt ->
    <<X:128/big-unsigned-integer>> = crypto:strong_rand_bytes(16),
    iolist_to_binary(io_lib:format("~32.16.0b", [X])).

-spec hash(algorithm_rw(), emqx_passwd:password()) ->
    {emqx_passwd:password_hash(), emqx_passwd:salt()}.
hash(#{name := bcrypt, salt_rounds := _} = Algorithm, Password) ->
    Salt0 = gen_salt(Algorithm),
    Hash = emqx_passwd:hash({bcrypt, Salt0}, Password),
    Salt = Hash,
    {Hash, Salt};
hash(
    #{
        name := pbkdf2,
        mac_fun := MacFun,
        iterations := Iterations
    } = Algorithm,
    Password
) ->
    Salt = gen_salt(Algorithm),
    DKLength = maps:get(dk_length, Algorithm, undefined),
    Hash = emqx_passwd:hash({pbkdf2, MacFun, Salt, Iterations, DKLength}, Password),
    {Hash, Salt};
hash(#{name := Other, salt_position := SaltPosition} = Algorithm, Password) ->
    Salt =
        case SaltPosition of
            disable -> <<>>;
            _ -> gen_salt(Algorithm)
        end,
    Hash = emqx_passwd:hash({Other, Salt, SaltPosition}, Password),
    {Hash, Salt}.

-spec check_password(
    algorithm(),
    emqx_passwd:salt(),
    emqx_passwd:password_hash(),
    emqx_passwd:password()
) -> boolean().
check_password(#{name := bcrypt}, _Salt, PasswordHash, Password) ->
    emqx_passwd:check_pass({bcrypt, PasswordHash}, PasswordHash, Password);
check_password(
    #{
        name := pbkdf2,
        mac_fun := MacFun,
        iterations := Iterations
    } = Algorithm,
    Salt,
    PasswordHash,
    Password
) ->
    DKLength = maps:get(dk_length, Algorithm, undefined),
    emqx_passwd:check_pass({pbkdf2, MacFun, Salt, Iterations, DKLength}, PasswordHash, Password);
check_password(#{name := Other, salt_position := SaltPosition}, Salt, PasswordHash, Password) ->
    emqx_passwd:check_pass({Other, Salt, SaltPosition}, PasswordHash, Password).

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

rw_refs() ->
    union_selector(rw).

ro_refs() ->
    union_selector(ro).

api_refs() ->
    union_selector(api).

sc(Type, Meta) -> hoconsc:mk(Type, Meta).

union_selector(Kind) ->
    fun
        (all_union_members) -> refs(Kind);
        ({value, #{<<"name">> := <<"bcrypt">>}}) -> [bcrypt_ref(Kind)];
        ({value, #{<<"name">> := <<"pbkdf2">>}}) -> [pbkdf2_ref(Kind)];
        ({value, #{<<"name">> := _}}) -> [simple_ref(Kind)];
        ({value, _}) -> throw(#{reason => "algorithm_name_missing"})
    end.

refs(Kind) ->
    [
        bcrypt_ref(Kind),
        pbkdf2_ref(Kind),
        simple_ref(Kind)
    ].

pbkdf2_ref(_) ->
    hoconsc:ref(?MODULE, pbkdf2).

bcrypt_ref(rw) ->
    hoconsc:ref(?MODULE, bcrypt_rw);
bcrypt_ref(api) ->
    hoconsc:ref(?MODULE, bcrypt_rw_api);
bcrypt_ref(_) ->
    hoconsc:ref(?MODULE, bcrypt).

simple_ref(_) ->
    hoconsc:ref(?MODULE, simple).
