%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_cth_listener).

-include_lib("esockd/include/esockd.hrl").

-export([
    reload_listener_with_ppv2/1,
    reload_listener_with_ppv2/2,
    reload_listener_without_ppv2/1
]).

-export([meck_recv_ppv2/1, clear_meck_recv_ppv2/1]).

-define(CLIENT_OPTS(PORT, SNI), #{
    host => "127.0.0.1",
    port => PORT,
    sni => SNI,
    proto_ver => v5,
    connect_timeout => 5,
    ssl => false
}).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

reload_listener_with_ppv2(Path = [listeners, _Type, _Name]) ->
    reload_listener_with_ppv2(Path, <<>>).

reload_listener_with_ppv2(Path = [listeners, Type, Name], DefaultSni) when
    Type == tcp; Type == ws
->
    Cfg = emqx_config:get(Path),
    ok = emqx_config:put(Path, Cfg#{proxy_protocol => true}),
    ok = emqx_listeners:restart_listener(
        emqx_listeners:listener_id(Type, Name)
    ),
    ok = meck_recv_ppv2(Type),
    client_conn_fn(Type, maps:get(bind, Cfg), DefaultSni).

client_conn_fn(tcp, Bind, Sni) ->
    client_conn_fn_gen(connect, ?CLIENT_OPTS(bind2port(Bind), Sni));
client_conn_fn(ws, Bind, Sni) ->
    client_conn_fn_gen(ws_connect, ?CLIENT_OPTS(bind2port(Bind), Sni)).

bind2port({_, Port}) -> Port;
bind2port(Port) when is_integer(Port) -> Port.

client_conn_fn_gen(Connect, Opts0) ->
    fun(ClientId, Opts1) ->
        Opts2 = maps:merge(Opts0, Opts1#{clientid => ClientId}),
        Sni = maps:get(sni, Opts2, undefined),
        NOpts = prepare_sni_for_meck(Sni, Opts2),
        {ok, C} = emqtt:start_link(NOpts),
        case emqtt:Connect(C) of
            {ok, _} -> {ok, C};
            {error, _} = Err -> Err
        end
    end.

prepare_sni_for_meck(ClientSni, Opts) when is_binary(ClientSni) ->
    ServerSni =
        case ClientSni of
            disable -> undefined;
            _ -> ClientSni
        end,
    persistent_term:put(current_client_sni, ServerSni),
    case maps:get(ssl, Opts, false) of
        false ->
            Opts;
        true ->
            SslOpts = maps:get(ssl_opts, Opts, #{}),
            Opts#{ssl_opts => [{server_name_indication, ClientSni} | SslOpts]}
    end.

reload_listener_without_ppv2(Path = [listeners, Type, Name]) when
    Type == tcp; Type == ws
->
    Cfg = emqx_config:get(Path),
    ok = emqx_config:put(Path, Cfg#{proxy_protocol => false}),
    ok = emqx_listeners:restart_listener(
        emqx_listeners:listener_id(Type, Name)
    ),
    ok = clear_meck_recv_ppv2(Type).

meck_recv_ppv2(tcp) ->
    ok = meck:new(esockd_proxy_protocol, [passthrough, no_history, no_link]),
    ok = meck:expect(
        esockd_proxy_protocol,
        recv,
        fun(Transport, Socket, _Timeout) ->
            SNI = persistent_term:get(current_client_sni, undefined),
            {ok, {SrcAddr, SrcPort}} = Transport:peername(Socket),
            {ok, {DstAddr, DstPort}} = Transport:sockname(Socket),
            ProxySocket = #proxy_socket{
                inet = inet4,
                socket = Socket,
                src_addr = SrcAddr,
                dst_addr = DstAddr,
                src_port = SrcPort,
                dst_port = DstPort,
                pp2_additional_info = [{pp2_authority, SNI}]
            },
            %% See `esockd_proxy_protocol:recv/3` implementation.
            case Transport of
                esockd_transport ->
                    {ok, ProxySocket};
                esockd_socket ->
                    ProxyAttrs = esockd_proxy_protocol:get_proxy_attrs(ProxySocket),
                    ok = socket:setopt(Socket, {otp, meta}, ProxyAttrs),
                    {ok, Socket}
            end
        end
    );
meck_recv_ppv2(ws) ->
    ok = meck:new(ranch_tcp, [passthrough, no_history, no_link]),
    ok = meck:expect(
        ranch_tcp,
        recv_proxy_header,
        fun(Socket, _Timeout) ->
            SNI = persistent_term:get(current_client_sni, undefined),
            {ok, {SrcAddr, SrcPort}} = esockd_transport:peername(Socket),
            {ok, {DstAddr, DstPort}} = esockd_transport:sockname(Socket),
            {ok, #{
                authority => SNI,
                command => proxy,
                dest_address => DstAddr,
                dest_port => DstPort,
                src_address => SrcAddr,
                src_port => SrcPort,
                transport_family => ipv4,
                transport_protocol => stream,
                version => 2
            }}
        end
    ).

clear_meck_recv_ppv2(tcp) ->
    ok = meck:unload(esockd_proxy_protocol);
clear_meck_recv_ppv2(ws) ->
    ok = meck:unload(ranch_tcp).
