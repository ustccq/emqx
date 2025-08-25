%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_dashboard_schema).

-include_lib("hocon/include/hoconsc.hrl").

-export([
    roots/0,
    fields/1,
    namespace/0,
    desc/1
]).

-export([
    mfa_fields/0,
    https_converter/2
]).

-define(DAYS_7, 7 * 24 * 60 * 60 * 1000).

namespace() -> dashboard.
roots() -> ["dashboard"].

fields("dashboard") ->
    [
        {listeners,
            ?HOCON(
                ?R_REF("listeners"),
                #{desc => ?DESC(listeners)}
            )},
        {default_username, fun default_username/1},
        {default_password, fun default_password/1},
        {sample_interval,
            ?HOCON(
                emqx_schema:timeout_duration_s(),
                #{
                    default => <<"10s">>,
                    desc => ?DESC(sample_interval),
                    importance => ?IMPORTANCE_HIDDEN,
                    validator => fun validate_sample_interval/1
                }
            )},
        {hwmark_expire_time,
            ?HOCON(
                emqx_schema:duration(),
                #{
                    default => <<"7d">>,
                    desc => ?DESC(hwmark_expire_time),
                    importance => ?IMPORTANCE_LOW,
                    validator => fun validate_hwmark_expire_time/1
                }
            )},
        {token_expired_time,
            ?HOCON(
                emqx_schema:duration(),
                #{
                    default => <<"60m">>,
                    desc => ?DESC(token_expired_time)
                }
            )},
        {password_expired_time,
            ?HOCON(
                emqx_schema:duration_s(),
                #{
                    default => 0,
                    desc => ?DESC(password_expired_time)
                }
            )},
        {cors, fun cors/1},
        {swagger_support, fun swagger_support/1},
        {i18n_lang, fun i18n_lang/1},
        {bootstrap_users_file,
            ?HOCON(
                binary(),
                #{
                    desc => ?DESC(bootstrap_users_file),
                    required => false,
                    default => <<>>,
                    deprecated => {since, "5.1.0"},
                    importance => ?IMPORTANCE_HIDDEN
                }
            )},
        {unsuccessful_login_max_attempts,
            ?HOCON(
                pos_integer(),
                #{
                    desc => ?DESC(unsuccessful_login_max_attempts),
                    required => false,
                    default => 5,
                    importance => ?IMPORTANCE_HIDDEN
                }
            )},
        {unsuccessful_login_lock_duration,
            ?HOCON(
                emqx_schema:duration_s(),
                #{
                    desc => ?DESC(unsuccessful_login_lock_duration),
                    required => false,
                    default => <<"10m">>,
                    importance => ?IMPORTANCE_HIDDEN
                }
            )},
        {unsuccessful_login_interval,
            ?HOCON(
                emqx_schema:duration_s(),
                #{
                    desc => ?DESC(unsuccessful_login_interval),
                    required => false,
                    default => <<"5m">>,
                    importance => ?IMPORTANCE_HIDDEN
                }
            )}
    ] ++ ee_fields();
fields("listeners") ->
    [
        {"http",
            ?HOCON(
                ?R_REF("http"),
                #{
                    desc => ?DESC("http_listener_settings"),
                    required => {false, recursively}
                }
            )},
        {"https",
            ?HOCON(
                ?R_REF("https"),
                #{
                    desc => ?DESC("ssl_listener_settings"),
                    required => {false, recursively},
                    converter => fun ?MODULE:https_converter/2
                }
            )}
    ];
fields("http") ->
    [
        enable(true),
        bind(18083)
        | common_listener_fields()
    ];
fields("https") ->
    [
        enable(false),
        bind(18084),
        ssl_options()
        | common_listener_fields()
    ];
fields("ssl_options") ->
    server_ssl_options();
fields("mfa_settings") ->
    mfa_fields().

mfa_fields() ->
    [
        {mechanism,
            ?HOCON(
                hoconsc:enum([totp]),
                #{
                    desc => ?DESC("mfa_mechanism"),
                    importance => ?IMPORTANCE_HIGH,
                    required => true
                }
            )}
    ].

ssl_options() ->
    {"ssl_options",
        ?HOCON(
            ?R_REF("ssl_options"),
            #{
                required => true,
                desc => ?DESC(ssl_options),
                importance => ?IMPORTANCE_HIGH
            }
        )}.

server_ssl_options() ->
    emqx_schema:server_ssl_opts_schema(#{}, true).

common_listener_fields() ->
    [
        {"num_acceptors",
            ?HOCON(
                integer(),
                #{
                    default => erlang:system_info(schedulers_online),
                    desc => ?DESC(num_acceptors),
                    importance => ?IMPORTANCE_MEDIUM
                }
            )},
        {"max_connections",
            ?HOCON(
                integer(),
                #{
                    default => 512,
                    desc => ?DESC(max_connections),
                    importance => ?IMPORTANCE_HIGH
                }
            )},
        {"backlog",
            ?HOCON(
                integer(),
                #{
                    default => 1024,
                    desc => ?DESC(backlog),
                    importance => ?IMPORTANCE_LOW
                }
            )},
        {"send_timeout",
            ?HOCON(
                emqx_schema:duration(),
                #{
                    default => <<"10s">>,
                    desc => ?DESC(send_timeout),
                    importance => ?IMPORTANCE_LOW
                }
            )},
        {"inet6",
            ?HOCON(
                boolean(),
                #{
                    default => false,
                    desc => ?DESC(inet6),
                    importance => ?IMPORTANCE_LOW
                }
            )},
        {"ipv6_v6only",
            ?HOCON(
                boolean(),
                #{
                    default => false,
                    desc => ?DESC(ipv6_v6only),
                    importance => ?IMPORTANCE_LOW
                }
            )},
        {"proxy_header",
            ?HOCON(
                boolean(),
                #{
                    desc => ?DESC(proxy_header),
                    default => false,
                    importance => ?IMPORTANCE_MEDIUM
                }
            )}
    ].

enable(Bool) ->
    {"enable",
        ?HOCON(
            boolean(),
            #{
                default => Bool,
                required => false,
                %% deprecated because we use port number =:= 0 to disable
                deprecated => {since, "5.1.0"},
                importance => ?IMPORTANCE_HIDDEN,
                desc => ?DESC(listener_enable)
            }
        )}.

bind(Port) ->
    {"bind",
        ?HOCON(
            emqx_schema:ip_port(),
            #{
                default => 0,
                required => false,
                example => "0.0.0.0:" ++ integer_to_list(Port),
                importance => ?IMPORTANCE_HIGH,
                desc => ?DESC(bind)
            }
        )}.

desc("dashboard") ->
    ?DESC(desc_dashboard);
desc("listeners") ->
    ?DESC(desc_listeners);
desc("http") ->
    ?DESC(desc_http);
desc("https") ->
    ?DESC(desc_https);
desc("ssl_options") ->
    ?DESC(ssl_options);
desc("mfa_settings") ->
    ?DESC(mfa_settings);
desc(_) ->
    undefined.

default_username(type) -> binary();
default_username(default) -> <<"admin">>;
default_username(required) -> true;
default_username(desc) -> ?DESC(default_username);
default_username('readOnly') -> true;
%% username is hidden but password is not,
%% this is because we want to force changing 'admin' user's password.
%% instead of suggesting to create a new user --- which could be
%% more prone to leaving behind 'admin' user's password unchanged without detection.
default_username(importance) -> ?IMPORTANCE_HIDDEN;
default_username(_) -> undefined.

default_password(type) -> emqx_schema_secret:secret();
default_password(default) -> <<"public">>;
default_password(required) -> true;
default_password('readOnly') -> true;
default_password(sensitive) -> true;
default_password(converter) -> fun password_converter/2;
default_password(desc) -> ?DESC(default_password);
default_password(importance) -> ?IMPORTANCE_LOW;
default_password(_) -> undefined.

cors(type) -> boolean();
cors(default) -> false;
cors(required) -> false;
cors(desc) -> ?DESC(cors);
cors(_) -> undefined.

swagger_support(type) -> boolean();
swagger_support(default) -> true;
swagger_support(desc) -> ?DESC(swagger_support);
swagger_support(_) -> undefined.

%% TODO: change it to string type
%% It will be up to the dashboard package which languages to support
i18n_lang(type) -> ?ENUM([en, zh]);
i18n_lang(default) -> en;
i18n_lang('readOnly') -> true;
i18n_lang(desc) -> ?DESC(i18n_lang);
i18n_lang(importance) -> ?IMPORTANCE_HIDDEN;
i18n_lang(_) -> undefined.

validate_sample_interval(Second) ->
    case Second >= 1 andalso Second =< 60 andalso (60 rem Second =:= 0) of
        true ->
            ok;
        false ->
            Msg = "must be between 1 and 60 and be a divisor of 60.",
            {error, Msg}
    end.

%% Cannot allow >7d because dashboard monitor data is only kept for 7 days
validate_hwmark_expire_time(ExpireTime) ->
    case ExpireTime >= 1 andalso ExpireTime =< ?DAYS_7 of
        true ->
            ok;
        false ->
            Msg = "must be between 1s and 7d.",
            {error, Msg}
    end.

https_converter(undefined, _Opts) ->
    %% no https listener configured
    undefined;
https_converter(Conf, Opts) ->
    convert_ssl_layout(Conf, Opts).

convert_ssl_layout(Conf = #{<<"ssl_options">> := _}, _Opts) ->
    Conf;
convert_ssl_layout(Conf = #{}, _Opts) ->
    Keys = lists:map(fun({K, _}) -> list_to_binary(K) end, server_ssl_options()),
    SslOpts = maps:with(Keys, Conf),
    Conf1 = maps:without(Keys, Conf),
    Conf1#{<<"ssl_options">> => SslOpts}.

password_converter(undefined, _HoconOpts) ->
    undefined;
password_converter(I, HoconOpts) when is_integer(I) ->
    password_converter(integer_to_binary(I), HoconOpts);
password_converter(X, HoconOpts) ->
    emqx_schema_secret:convert_secret(X, HoconOpts).

mfa_schema() ->
    ?HOCON(
        hoconsc:union([none, ?REF("mfa_settings")]),
        #{
            desc => ?DESC("default_mfa"),
            default => none,
            required => false,
            importance => ?IMPORTANCE_LOW
        }
    ).

ee_fields() ->
    [
        {default_mfa, mfa_schema()},
        {sso,
            ?HOCON(
                ?R_REF(emqx_dashboard_sso_schema, sso),
                #{required => {false, recursively}}
            )}
    ].
