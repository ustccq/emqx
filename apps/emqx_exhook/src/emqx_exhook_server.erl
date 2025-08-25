%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_exhook_server).

-include("emqx_exhook.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx_hooks.hrl").

%% The exhook proto version should be fixed as `v3` in EMQX v5.x
%% to make sure the exhook proto version is compatible
-define(PB_CLIENT_MOD, emqx_exhook_v_3_hook_provider_client).

%% Load/Unload
-export([
    load/2,
    unload/1,
    health_check/1
]).

%% APIs
-export([call/3]).

%% Infos
-export([
    name/1,
    hooks/1,
    format/1,
    failed_action/1
]).

-ifdef(TEST).
-export([hk2func/1]).
-endif.

-type service() :: #{
    %% Server name (equal to grpc client channel name)
    name := binary(),
    %% The function options
    options := map(),
    %% gRPC channel pid
    channel := pid(),
    %% Registered hook names and options
    hookspec := #{hookpoint() => map()},
    %% Metrcis name prefix
    prefix := list()
}.

-type hookpoint() ::
    'client.connect'
    | 'client.connack'
    | 'client.connected'
    | 'client.disconnected'
    | 'client.authenticate'
    | 'client.authorize'
    | 'client.subscribe'
    | 'client.unsubscribe'
    | 'session.created'
    | 'session.subscribed'
    | 'session.unsubscribed'
    | 'session.resumed'
    | 'session.discarded'
    | 'session.takenover'
    | 'session.terminated'
    | 'message.publish'
    | 'message.delivered'
    | 'message.acked'
    | 'message.dropped'.

-export_type([service/0, hookpoint/0]).

-dialyzer({nowarn_function, [inc_metrics/2]}).

-elvis([
    {elvis_style, dont_repeat_yourself, disable},
    {elvis_style, no_catch_expressions, disable}
]).

%%--------------------------------------------------------------------
%% Load/Unload APIs
%%--------------------------------------------------------------------

-spec load(binary(), map()) -> {ok, service()} | {error, term()} | {load_error, term()} | disable.
load(_Name, #{enable := false}) ->
    disable;
load(Name, #{request_timeout := Timeout, failed_action := FailedAction} = Opts) ->
    ReqOpts = #{timeout => Timeout, failed_action => FailedAction},
    case channel_opts(Opts) of
        {ok, {SvrAddr, ClientOpts}} ->
            case start_client_channel(Name, SvrAddr, ClientOpts) of
                {ok, _ChannPoolPid} ->
                    case do_init(Name, ReqOpts) of
                        {ok, HookSpecs} ->
                            %% Register metrics
                            Prefix = lists:flatten(io_lib:format("exhook.~ts.", [Name])),
                            ensure_metrics(Prefix, HookSpecs),
                            %% Ensure hooks
                            ensure_hooks(HookSpecs),
                            {ok, #{
                                name => Name,
                                options => ReqOpts,
                                channel => _ChannPoolPid,
                                hookspec => HookSpecs,
                                prefix => Prefix
                            }};
                        {error, Reason} ->
                            _ = emqx_exhook_sup:stop_grpc_client_channel(Name),
                            {load_error, Reason}
                    end;
                {error, _} = E ->
                    E
            end;
        Error ->
            Error
    end.

%% @private
channel_opts(Opts = #{url := URL, socket_options := SockOpts}) ->
    ClientOpts = #{
        pool_size => maps:get(pool_size, Opts, erlang:system_info(schedulers))
    },
    GunOpts = #{
        transport => tcp,
        tcp_opts => maps:to_list(SockOpts),
        %% NOTE: Disable retries by default, emulating 0.6.x behavior.
        retry => 0
    },
    case uri_string:parse(URL) of
        #{scheme := <<"http">>, host := Host, port := Port} ->
            NClientOpts = ClientOpts#{
                gun_opts => GunOpts
            },
            {ok, {format_http_uri("http", Host, Port), NClientOpts}};
        #{scheme := <<"https">>, host := Host, port := Port} ->
            SslOpts =
                case maps:get(ssl, Opts, undefined) of
                    undefined ->
                        [];
                    #{enable := false} ->
                        [];
                    MapOpts ->
                        filter(
                            [
                                {cacertfile, maps:get(cacertfile, MapOpts, undefined)},
                                {certfile, maps:get(certfile, MapOpts, undefined)},
                                {keyfile, maps:get(keyfile, MapOpts, undefined)}
                            ]
                        )
                end,
            NClientOpts = ClientOpts#{
                gun_opts => GunOpts#{
                    transport => ssl,
                    tls_opts => SslOpts
                }
            },
            {ok, {format_http_uri("https", Host, Port), NClientOpts}};
        Error ->
            {error, {bad_server_url, URL, Error}}
    end.

%% @private
format_http_uri(Scheme, Host, Port) ->
    lists:flatten(io_lib:format("~ts://~ts:~w", [Scheme, Host, Port])).

%% @private
filter(Ls) ->
    [E || E <- Ls, E /= undefined].

%% @private
-spec start_client_channel(binary(), string(), map()) -> {ok, pid()} | {error, term()}.
start_client_channel(Name, SvrAddr, ClientOpts) ->
    case emqx_exhook_sup:start_grpc_client_channel(Name, SvrAddr, ClientOpts) of
        {ok, ChannPoolPid} ->
            {ok, ChannPoolPid};
        {error, {already_started, ChannPoolPid}} ->
            {ok, ChannPoolPid};
        {error, _} = E ->
            E
    end.

%% @private
do_init(ChannName, ReqOpts) ->
    %% BrokerInfo defined at: exhook.protos
    BrokerInfo = maps:with(
        [version, sysdescr, uptime, datetime],
        maps:from_list(emqx_sys:info())
    ),
    Req = #{broker => BrokerInfo},
    case do_call(ChannName, undefined, 'on_provider_loaded', Req, ReqOpts) of
        {ok, InitialResp} ->
            try
                {ok, resolve_hookspec(maps:get(hooks, InitialResp, []))}
            catch
                _:Reason:Stk ->
                    ?SLOG(error, #{
                        msg => "failed_to_init_channel",
                        channel_name => ChannName,
                        reason => Reason,
                        stacktrace => Stk
                    }),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
resolve_hookspec(HookSpecs) when is_list(HookSpecs) ->
    MessageHooks = message_hooks(),
    AvailableHooks = available_hooks(),
    lists:foldr(
        fun(HookSpec, Acc) ->
            case maps:get(name, HookSpec, undefined) of
                undefined ->
                    Acc;
                Name0 ->
                    Name =
                        try
                            binary_to_existing_atom(Name0, utf8)
                        catch
                            T:R:_ -> {T, R}
                        end,
                    case {lists:member(Name, AvailableHooks), lists:member(Name, MessageHooks)} of
                        {false, _} ->
                            error({unknown_hookpoint, Name0});
                        {true, false} ->
                            Acc#{Name => #{}};
                        {true, true} ->
                            Acc#{
                                Name => #{
                                    topics => maps:get(topics, HookSpec, [])
                                }
                            }
                    end
            end
        end,
        #{},
        HookSpecs
    ).

%% @private
ensure_metrics(Prefix, HookSpecs) ->
    Keys = [
        list_to_atom(Prefix ++ atom_to_list(Hookpoint))
     || Hookpoint <- maps:keys(HookSpecs)
    ],
    lists:foreach(fun emqx_metrics:ensure/1, Keys).

%% @private
ensure_hooks(HookSpecs) ->
    lists:foreach(
        fun(Hookpoint) ->
            case lists:keyfind(Hookpoint, 1, ?ENABLED_HOOKS) of
                false ->
                    ?SLOG(error, #{msg => "skipped_unknown_hookpoint", hookpoint => Hookpoint});
                {Hookpoint, {M, F, A}} ->
                    emqx_hooks:put(Hookpoint, {M, F, A}, ?HP_EXHOOK),
                    ets:update_counter(?HOOKS_REF_COUNTER, Hookpoint, {2, 1}, {Hookpoint, 0})
            end
        end,
        maps:keys(HookSpecs)
    ).

-spec unload(service()) -> ok.
unload(#{name := Name, options := ReqOpts, hookspec := HookSpecs}) ->
    _ = may_unload_hooks(HookSpecs),
    _ = do_deinit(Name, ReqOpts),
    _ = emqx_exhook_sup:stop_grpc_client_channel(Name),
    ok.

%% @private
may_unload_hooks(HookSpecs) ->
    lists:foreach(
        fun(Hookpoint) ->
            case ets:update_counter(?HOOKS_REF_COUNTER, Hookpoint, {2, -1}, {Hookpoint, 0}) of
                Cnt when Cnt =< 0 ->
                    case lists:keyfind(Hookpoint, 1, ?ENABLED_HOOKS) of
                        {Hookpoint, {M, F, _A}} ->
                            emqx_hooks:del(Hookpoint, {M, F});
                        _ ->
                            ok
                    end,
                    ets:delete(?HOOKS_REF_COUNTER, Hookpoint);
                _ ->
                    ok
            end
        end,
        maps:keys(HookSpecs)
    ).

%% @private
do_deinit(Name, ReqOpts) ->
    %% Override the request timeout to deinit grpc server to
    %% avoid emqx_exhook_mgr force killed by upper supervisor
    NReqOpts = ReqOpts#{timeout => ?SERVER_FORCE_SHUTDOWN_TIMEOUT},
    _ = do_call(Name, undefined, 'on_provider_unloaded', #{}, NReqOpts),
    ok.

-spec health_check(map() | undefined) -> boolean() | skip | disable.
health_check(#{enable := false}) ->
    disable;
health_check(#{status := disconnected}) ->
    %% for disconnected Service, skip health check to follow auto_reconnect timer
    skip;
health_check(#{name := Name, request_timeout := Timeout} = _Opts) ->
    %% check all workers
    case grpc_client_sup:workers(Name) of
        [] ->
            false;
        Workers ->
            lists:all(
                fun({_, WorkerPid}) ->
                    case
                        grpc_client:health_check(
                            WorkerPid,
                            #{timeout => Timeout, channel => Name}
                        )
                    of
                        ok -> true;
                        _ -> false
                    end
                end,
                Workers
            )
    end.

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

name(#{name := Name}) ->
    Name.

-spec hooks(service()) -> list().
hooks(#{hookspec := Hooks}) ->
    FoldFun = fun(Hook, Params, Acc) ->
        [
            #{
                name => Hook,
                params => Params
            }
            | Acc
        ]
    end,
    maps:fold(FoldFun, [], Hooks).

-spec format(service()) -> list().
format(#{name := Name, hookspec := Hooks}) ->
    lists:flatten(
        io_lib:format("name=~ts, hooks=~0p, active=true", [Name, Hooks])
    ).

-spec call(hookpoint(), map(), service()) ->
    ignore
    | {ok, Resp :: term()}
    | {error, term()}.
call(
    Hookpoint,
    Req,
    #{
        name := ChannName,
        options := ReqOpts,
        hookspec := Hooks,
        prefix := Prefix
    }
) ->
    case maps:get(Hookpoint, Hooks, undefined) of
        undefined ->
            ignore;
        Opts ->
            NeedCall =
                case lists:member(Hookpoint, message_hooks()) of
                    false ->
                        true;
                    _ ->
                        #{message := #{topic := Topic}} = Req,
                        match_topic_filter(Topic, maps:get(topics, Opts, []))
                end,
            case NeedCall of
                false ->
                    ignore;
                _ ->
                    inc_metrics(Prefix, Hookpoint),
                    GrpcFun = hk2func(Hookpoint),
                    do_call(ChannName, Hookpoint, GrpcFun, Req, ReqOpts)
            end
    end.

%% @private
inc_metrics(IncFun, Name) when is_function(IncFun) ->
    %% BACKW: e4.2.0-e4.2.2
    {env, [Prefix | _]} = erlang:fun_info(IncFun, env),
    inc_metrics(Prefix, Name);
inc_metrics(Prefix, Name) when is_list(Prefix) ->
    emqx_metrics:inc(list_to_atom(Prefix ++ atom_to_list(Name))).

-compile({inline, [match_topic_filter/2]}).
match_topic_filter(_, []) ->
    true;
match_topic_filter(TopicName, TopicFilter) ->
    lists:any(fun(F) -> emqx_topic:match(TopicName, F) end, TopicFilter).

-ifdef(TEST).
-define(CALL_PB_CLIENT(ChanneName, Fun, Req, Options),
    apply(?PB_CLIENT_MOD, Fun, [Req, #{<<"channel">> => ChannName}, Options])
).
-else.
-define(CALL_PB_CLIENT(ChanneName, Fun, Req, Options),
    apply(?PB_CLIENT_MOD, Fun, [Req, Options])
).
-endif.

%% @private
-spec do_call(binary(), atom(), atom(), map(), map()) -> {ok, map()} | {error, term()}.
do_call(ChannName, Hookpoint, Fun, Req, ReqOpts) ->
    NReq = Req#{meta => emqx_exhook_handler:request_meta()},
    Options = ReqOpts#{
        channel => ChannName,
        key_dispatch => key_dispatch(NReq)
    },
    ?SLOG(debug, #{
        msg => "do_call",
        module => ?PB_CLIENT_MOD,
        function => Fun,
        req => NReq,
        options => Options
    }),
    case catch ?CALL_PB_CLIENT(ChanneName, Fun, NReq, Options) of
        {ok, Resp, Metadata} ->
            ?SLOG(debug, #{msg => "do_call_ok", resp => Resp, metadata => Metadata}),
            update_metrics(Hookpoint, ChannName, fun emqx_exhook_metrics:succeed/2),
            {ok, Resp};
        {error, {Code, Msg}, _Metadata} ->
            ?SLOG(error, #{
                msg => "exhook_call_error",
                module => ?PB_CLIENT_MOD,
                function => Fun,
                req => NReq,
                options => Options,
                code => Code,
                packet => Msg
            }),
            update_metrics(Hookpoint, ChannName, fun emqx_exhook_metrics:failed/2),
            {error, {Code, Msg}};
        {error, Reason} ->
            ?SLOG(error, #{
                msg => "exhook_call_error",
                module => ?PB_CLIENT_MOD,
                function => Fun,
                req => NReq,
                options => Options,
                reason => Reason
            }),
            update_metrics(Hookpoint, ChannName, fun emqx_exhook_metrics:failed/2),
            {error, Reason};
        {'EXIT', {Reason, Stk}} ->
            ?SLOG(error, #{
                msg => "exhook_call_exception",
                module => ?PB_CLIENT_MOD,
                function => Fun,
                req => NReq,
                options => Options,
                stacktrace => Stk
            }),
            update_metrics(Hookpoint, ChannName, fun emqx_exhook_metrics:failed/2),
            {error, Reason}
    end.

update_metrics(undefined, _ChannName, _Fun) ->
    ok;
update_metrics(Hookpoint, ChannName, Fun) ->
    Fun(ChannName, Hookpoint).

failed_action(#{options := Opts}) ->
    maps:get(failed_action, Opts).

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

-compile({inline, [hk2func/1]}).
hk2func('client.connect') -> 'on_client_connect';
hk2func('client.connack') -> 'on_client_connack';
hk2func('client.connected') -> 'on_client_connected';
hk2func('client.disconnected') -> 'on_client_disconnected';
hk2func('client.authenticate') -> 'on_client_authenticate';
hk2func('client.authorize') -> 'on_client_authorize';
hk2func('client.subscribe') -> 'on_client_subscribe';
hk2func('client.unsubscribe') -> 'on_client_unsubscribe';
hk2func('session.created') -> 'on_session_created';
hk2func('session.subscribed') -> 'on_session_subscribed';
hk2func('session.unsubscribed') -> 'on_session_unsubscribed';
hk2func('session.resumed') -> 'on_session_resumed';
hk2func('session.discarded') -> 'on_session_discarded';
hk2func('session.takenover') -> 'on_session_takenover';
hk2func('session.terminated') -> 'on_session_terminated';
hk2func('message.publish') -> 'on_message_publish';
hk2func('message.delivered') -> 'on_message_delivered';
hk2func('message.acked') -> 'on_message_acked';
hk2func('message.dropped') -> 'on_message_dropped'.

-compile({inline, [message_hooks/0]}).
message_hooks() ->
    [
        'message.publish',
        'message.delivered',
        'message.acked',
        'message.dropped'
    ].

-compile({inline, [available_hooks/0]}).
available_hooks() ->
    [
        'client.connect',
        'client.connack',
        'client.connected',
        'client.disconnected',
        'client.authenticate',
        'client.authorize',
        'client.subscribe',
        'client.unsubscribe',
        'session.created',
        'session.subscribed',
        'session.unsubscribed',
        'session.resumed',
        'session.discarded',
        'session.takenover',
        'session.terminated'
        | message_hooks()
    ].

%% @doc Get dispatch_key for each request
key_dispatch(_Req = #{clientinfo := #{clientid := ClientId}}) ->
    ClientId;
key_dispatch(_Req = #{conninfo := #{clientid := ClientId}}) ->
    ClientId;
key_dispatch(_Req = #{message := #{from := From}}) ->
    From;
key_dispatch(_Req) ->
    self().
