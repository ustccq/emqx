%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_license).

-include("emqx_license.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("typerefl/include/types.hrl").

-behaviour(emqx_config_handler).
-behaviour(emqx_config_backup).

-export([
    pre_config_update/3,
    post_config_update/5
]).

-export([
    load/0,
    check/2,
    unload/0,
    read_license/0,
    read_license/1,
    update_key/1,
    update_setting/1
]).

-export([import_config/2]).

-define(CONF_KEY_PATH, [license]).

%% Give the license app the highest priority.
%% We don't define it in the emqx_hooks.hrl becasue that is an opensource code
%% and can be changed by the communitiy.
-define(HP_LICENSE, 2000).

-define(IS_CLIENTID_TO_BE_ASSIGENED(X), (X =:= <<>> orelse X =:= undefined)).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

-spec read_license() -> {ok, emqx_license_parser:license()} | {error, term()}.
read_license() ->
    read_license(emqx:get_config(?CONF_KEY_PATH)).

-spec load() -> ok.
load() ->
    emqx_license_cli:load(),
    emqx_conf:add_handler(?CONF_KEY_PATH, ?MODULE),
    add_license_hook().

-spec unload() -> ok.
unload() ->
    %% Delete the hook. This means that if the user calls
    %% `application:stop(emqx_license).` from the shell, then here should no limitations!
    del_license_hook(),
    emqx_conf:remove_handler(?CONF_KEY_PATH),
    emqx_license_cli:unload().

-spec update_key(binary() | string()) ->
    {ok, emqx_config:update_result()} | {error, emqx_config:update_error()}.
update_key(Value) when is_binary(Value); is_list(Value) ->
    Value1 = emqx_utils_conv:bin(Value),
    Result = exec_config_update({key, Value1}),
    handle_config_update_result(Result).

update_setting(Setting) when is_map(Setting) ->
    Result = exec_config_update({setting, Setting}),
    handle_config_update_result(Result).

exec_config_update(Param) ->
    emqx_conf:update(
        ?CONF_KEY_PATH,
        Param,
        #{rawconf_with_defaults => true, override_to => cluster}
    ).

%%------------------------------------------------------------------------------
%% emqx_hooks
%%------------------------------------------------------------------------------

check(#{clientid := ClientId}, AckProps) ->
    case emqx_license_checker:limits() of
        {ok, #{max_sessions := ?ERR_EXPIRED}} ->
            ?SLOG_THROTTLE(error, #{msg => connection_rejected_due_to_license_expired}, #{
                tag => "LICENSE"
            }),
            {stop, {error, ?RC_QUOTA_EXCEEDED}};
        {ok, #{max_sessions := ?ERR_MAX_UPTIME}} ->
            ?SLOG_THROTTLE(
                error, #{msg => connection_rejected_due_to_trial_license_uptime_limit}, #{
                    tag => "LICENSE"
                }
            ),
            {stop, {error, ?RC_QUOTA_EXCEEDED}};
        {ok, #{max_sessions := MaxSessions}} ->
            case is_max_clients_exceeded(MaxSessions) andalso is_new_client(ClientId) of
                true ->
                    ?SLOG_THROTTLE(
                        error,
                        #{msg => connection_rejected_due_to_license_limit_reached},
                        #{tag => "LICENSE"}
                    ),
                    {stop, {error, ?RC_QUOTA_EXCEEDED}};
                false ->
                    {ok, AckProps}
            end;
        {error, Reason} ->
            ?SLOG(
                error,
                #{
                    msg => "connection_rejected_due_to_license_not_loaded",
                    reason => Reason
                },
                #{tag => "LICENSE"}
            ),
            {stop, {error, ?RC_QUOTA_EXCEEDED}}
    end.

import_config(_Namespace, #{<<"license">> := Config}) ->
    OldConf = emqx:get_config(?CONF_KEY_PATH),
    case exec_config_update(Config) of
        {ok, #{config := NewConf}} ->
            Changed = maps:get(changed, emqx_utils_maps:diff_maps(NewConf, OldConf)),
            Changed1 = lists:map(fun(Key) -> [license, Key] end, maps:keys(Changed)),
            {ok, #{root_key => license, changed => Changed1}};
        Error ->
            {error, #{root_key => license, reason => Error}}
    end;
import_config(_Namespace, _RawConf) ->
    {ok, #{root_key => license, changed => []}}.

%%------------------------------------------------------------------------------
%% emqx_config_handler callbacks
%%------------------------------------------------------------------------------

pre_config_update(_, Cmd, Conf) ->
    {ok, do_update(Cmd, Conf)}.

post_config_update(_Path, {setting, _}, NewConf, _Old, _AppEnvs) ->
    {ok, NewConf};
post_config_update(_Path, _Cmd, NewConf, _Old, _AppEnvs) ->
    case read_license(NewConf) of
        {ok, License} ->
            {ok, emqx_license_checker:update(License)};
        {error, _} = Error ->
            Error
    end.

%%------------------------------------------------------------------------------
%% Private functions
%%------------------------------------------------------------------------------

add_license_hook() ->
    ok = emqx_hooks:put('client.connect', {?MODULE, check, []}, ?HP_LICENSE).

del_license_hook() ->
    _ = emqx_hooks:del('client.connect', {?MODULE, check, []}),
    ok.

do_update({key, Content}, Conf) when is_binary(Content); is_list(Content) ->
    case emqx_license_parser:parse(Content) of
        {ok, License} ->
            ok = no_violation(License),
            Conf#{<<"key">> => Content};
        {error, Reason} ->
            erlang:throw(Reason)
    end;
do_update({setting, Setting0}, Conf) ->
    #{<<"key">> := Key} = Conf,
    %% only allow updating dynamic_max_connections when it's BUSINESS_CRITICAL
    Setting =
        case emqx_license_parser:is_business_critical(Key) of
            true ->
                Setting0;
            false ->
                maps:without([<<"dynamic_max_connections">>], Setting0)
        end,
    maps:merge(Conf, Setting);
do_update(NewConf, _PrevConf) ->
    #{<<"key">> := NewKey} = NewConf,
    do_update({key, NewKey}, NewConf).

no_violation(License) ->
    case emqx_license_checker:no_violation(License) of
        ok ->
            ok;
        {error, Reason} ->
            throw(Reason)
    end.

%% Return 'true' if it is a client new to the cluster.
%% A client is new when it cannot be found in session registry.
is_new_client(ClientId) when ?IS_CLIENTID_TO_BE_ASSIGENED(ClientId) ->
    %% no client ID provided, yet to be randomly assigned,
    %% so it must be new
    true;
is_new_client(ClientId) ->
    %% it's a new client if no live session is found
    [] =:= emqx_cm:lookup_channels(ClientId).

is_max_clients_exceeded(MaxClients) when MaxClients =< ?NO_OVERSHOOT_SESSIONS_LIMIT ->
    emqx_license_resources:cached_connection_count() >= MaxClients;
is_max_clients_exceeded(MaxClients) ->
    Limit = MaxClients * ?SESSIONS_LIMIT_OVERSHOOT_FACTOR,
    emqx_license_resources:cached_connection_count() >= erlang:round(Limit).

read_license(#{key := Content}) ->
    emqx_license_parser:parse(Content).

handle_config_update_result({error, {post_config_update, ?MODULE, Error}}) ->
    {error, Error};
handle_config_update_result({error, _} = Error) ->
    Error;
handle_config_update_result({ok, #{post_config_update := #{emqx_license := Result}}}) ->
    {ok, Result}.
