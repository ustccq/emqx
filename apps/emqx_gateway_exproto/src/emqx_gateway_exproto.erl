%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

%% @doc The ExProto Gateway implement
-module(emqx_gateway_exproto).

-include_lib("emqx/include/logger.hrl").
-include_lib("emqx_gateway/include/emqx_gateway.hrl").

%% define a gateway named stomp
-gateway(#{
    name => exproto,
    callback_module => ?MODULE,
    config_schema_module => emqx_exproto_schema
}).

%% callback_module must implement the emqx_gateway_impl behaviour
-behaviour(emqx_gateway_impl).

%% callback for emqx_gateway_impl
-export([
    on_gateway_load/2,
    on_gateway_update/3,
    on_gateway_unload/2
]).

-import(
    emqx_gateway_utils,
    [
        normalize_config/1,
        start_listeners/4,
        stop_listeners/2,
        update_gateway/5
    ]
).

-define(MOD_CFG, #{
    frame_mod => emqx_exproto_frame,
    chann_mod => emqx_exproto_channel
}).

%%--------------------------------------------------------------------
%% emqx_gateway_impl callbacks
%%--------------------------------------------------------------------

on_gateway_load(
    _Gateway = #{
        name := GwName,
        config := Config
    },
    Ctx
) ->
    %% XXX: How to monitor it ?
    _ = start_grpc_client_channel(
        GwName,
        maps:get(handler, Config, undefined)
    ),
    %% XXX: How to monitor it ?
    _ = start_grpc_server(GwName, maps:get(server, Config, undefined)),

    Config1 = set_client_channel_and_service_name(GwName, Config),

    Listeners = emqx_gateway_utils:normalize_config(Config1),

    case
        start_listeners(
            Listeners, GwName, Ctx, ?MOD_CFG
        )
    of
        {ok, ListenerPids} ->
            {ok, ListenerPids, _GwState = #{ctx => Ctx}};
        {error, {Reason, Listener}} ->
            throw(
                {badconf, #{
                    key => listeners,
                    value => Listener,
                    reason => Reason
                }}
            )
    end.

on_gateway_update(Config, Gateway = #{config := OldConfig}, GwState = #{ctx := Ctx}) ->
    GwName = maps:get(name, Gateway),
    try
        ok = update_grpc_client_and_server(GwName, Config, OldConfig),

        Config1 = set_client_channel_and_service_name(GwName, Config),
        OldConfig1 = set_client_channel_and_service_name(GwName, OldConfig),

        {ok, NewPids} = update_gateway(Config1, OldConfig1, GwName, Ctx, ?MOD_CFG),
        {ok, NewPids, GwState}
    catch
        Class:Reason:Stk ->
            logger:error(
                "Failed to update ~ts; "
                "reason: {~0p, ~0p} stacktrace: ~0p",
                [GwName, Class, Reason, Stk]
            ),
            {error, Reason}
    end.

on_gateway_unload(
    _Gateway = #{
        name := GwName,
        config := Config
    },
    _GwState
) ->
    Listeners = emqx_gateway_utils:normalize_config(Config),
    stop_grpc_server(GwName),
    stop_grpc_client_channel(GwName),
    stop_listeners(GwName, Listeners).

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

update_grpc_client_and_server(GwName, NewConfig, OldConfig) ->
    ok = update_grpc_client_channel(GwName, NewConfig, OldConfig),
    update_grpc_server(GwName, NewConfig, OldConfig).

update_grpc_client_channel(GwName, NewConfig, OldConfig) ->
    case {maps:get(handler, NewConfig, undefined), maps:get(handler, OldConfig, undefined)} of
        {New, New} ->
            ok;
        {New, Old} ->
            stop_grpc_client_channel(Old),
            _ = start_grpc_client_channel(GwName, New),
            ok
    end,
    ok.

update_grpc_server(GwName, NewConfig, OldConfig) ->
    case {maps:get(server, NewConfig, undefined), maps:get(server, OldConfig, undefined)} of
        {New, New} ->
            ok;
        {New, _Old} ->
            stop_grpc_server(GwName),
            _ = start_grpc_server(GwName, New)
    end,
    ok.

start_grpc_server(GwName, Options = #{bind := ListenOn}) ->
    Services = #{
        protos => [emqx_exproto_pb],
        services => #{
            'emqx.exproto.v1.ConnectionAdapter' => emqx_exproto_gsvr
        }
    },
    SvrOptions =
        case emqx_utils_maps:deep_get([ssl, enable], Options, false) of
            false ->
                [];
            true ->
                Opts1 = maps:get(ssl, Options, #{}),
                Opts2 = maps:without([handshake_timeout], Opts1),
                SSLOpts = emqx_tls_lib:to_server_opts(tls, Opts2),
                [
                    {ssl_options, SSLOpts}
                ]
        end,
    ListenOnStr = emqx_listeners:format_bind(ListenOn),
    case grpc:start_server(GwName, ListenOn, Services, SvrOptions) of
        {ok, _SvrPid} ->
            console_print(
                "Start ~ts gRPC server on ~s successfully.~n",
                [GwName, ListenOnStr]
            );
        {error, Reason} ->
            ?ELOG(
                "Failed to start ~ts gRPC server on ~s, reason: ~0p",
                [GwName, ListenOnStr, Reason]
            ),
            throw(
                {badconf, #{
                    key => server,
                    value => Options,
                    reason => Reason
                }}
            )
    end;
start_grpc_server(_GwName, Options) ->
    throw(
        {badconf, #{
            key => server,
            value => Options,
            reason => invalid_grpc_server_confs
        }}
    ).

stop_grpc_server(GwName) ->
    _ = grpc:stop_server(GwName),
    console_print("Stop ~s gRPC server successfully.~n", [GwName]).

start_grpc_client_channel(
    GwName,
    Options = #{address := Address}
) ->
    #{host := Host, port := Port} =
        case emqx_http_lib:uri_parse(Address) of
            {ok, URIMap0} ->
                URIMap0;
            {error, _Reason} ->
                throw(
                    {badconf, #{
                        key => address,
                        value => Address,
                        reason => invalid_grpc_address
                    }}
                )
        end,
    SSLOpts = emqx_utils_maps:deep_get([ssl_options], Options, #{}),
    case maps:get(enable, SSLOpts, false) of
        false ->
            SvrAddr = compose_http_uri(http, Host, Port),
            ClientOpts = #{
                gun_opts => #{
                    %% NOTE: Disable retries by default, emulating 0.6.x behavior.
                    retry => 0
                }
            },
            grpc_client_sup:create_channel_pool(GwName, SvrAddr, ClientOpts);
        true ->
            SSLOpts1 = [{nodelay, true} | emqx_tls_lib:to_client_opts(SSLOpts)],
            ClientOpts = #{
                gun_opts => #{
                    transport => ssl,
                    tls_opts => SSLOpts1,
                    %% NOTE: Disable retries by default, emulating 0.6.x behavior.
                    retry => 0
                }
            },
            SvrAddr = compose_http_uri(https, Host, Port),
            grpc_client_sup:create_channel_pool(GwName, SvrAddr, ClientOpts)
    end;
start_grpc_client_channel(_GwName, Options) ->
    throw(
        {badconf, #{
            key => handler,
            value => Options,
            reason => invalid_grpc_client_confs
        }}
    ).

compose_http_uri(Scheme, Host0, Port) ->
    Host =
        case inet:is_ip_address(Host0) of
            true ->
                inet:ntoa(Host0);
            false when is_list(Host0) ->
                Host0
        end,

    lists:flatten(
        io_lib:format(
            "~s://~s:~w", [Scheme, Host, Port]
        )
    ).

stop_grpc_client_channel(GwName) ->
    _ = grpc_client_sup:stop_channel_pool(GwName),
    ok.

set_client_channel_and_service_name(GwName, Config) ->
    Config1 = maps:without([server, handler], Config),
    Config1#{
        handler => GwName,
        grpc_client_channel => GwName,
        grpc_client_service_name => get_service_name(Config)
    }.

get_service_name(Config) ->
    emqx_utils_maps:deep_get([handler, service_name], Config, 'ConnectionUnaryHandler').

-ifndef(TEST).
console_print(Fmt, Args) -> ?ULOG(Fmt, Args).
-else.
console_print(_Fmt, _Args) -> ok.
-endif.
