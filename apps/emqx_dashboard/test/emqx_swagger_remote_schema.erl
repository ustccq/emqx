%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_swagger_remote_schema).

-include_lib("typerefl/include/types.hrl").

-export([namespace/0, roots/0, fields/1]).
-import(hoconsc, [mk/2]).
roots() -> ["root"].
namespace() -> undefined.

fields("root") ->
    [
        {listeners,
            hoconsc:array(
                hoconsc:union([
                    hoconsc:ref(?MODULE, "ref1"),
                    hoconsc:ref(?MODULE, "ref2")
                ])
            )},
        {default_username, fun default_username/1},
        {default_password, fun default_password/1},
        {sample_interval, mk(emqx_schema:timeout_duration_s(), #{default => <<"10s">>})},
        {token_expired_time, mk(emqx_schema:duration(), #{default => <<"30m">>})}
    ];
fields("ref1") ->
    [
        {"protocol", hoconsc:enum([http, https])},
        {"port", mk(integer(), #{default => 18083})}
    ];
fields("ref2") ->
    [
        {page, mk(range(1, 100), #{desc => <<"good page">>})},
        {another_ref, hoconsc:ref(?MODULE, "ref3")}
    ];
fields("ref3") ->
    [
        {ip, mk(emqx_schema:ip_port(), #{desc => <<"IP:Port">>, example => "127.0.0.1:80"})},
        {version, mk(string(), #{desc => "a good version", example => "1.0.0"})}
    ].

default_username(type) -> string();
default_username(default) -> <<"admin">>;
default_username(required) -> true;
default_username(_) -> undefined.

default_password(type) -> string();
default_password(default) -> "public";
default_password(required) -> true;
default_password(_) -> undefined.
