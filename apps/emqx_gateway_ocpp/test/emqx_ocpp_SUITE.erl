%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_ocpp_SUITE).

-include("emqx_ocpp.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("emqx/include/asserts.hrl").

-compile(export_all).
-compile(nowarn_export_all).

-import(
    emqx_gateway_test_utils,
    [
        assert_fields_exist/2,
        request/2,
        request/3
    ]
).

%% erlfmt-ignore
-define(CONF_DEFAULT, <<"
    gateway.ocpp {
      mountpoint = \"ocpp/\"
      default_heartbeat_interval = \"60s\"
      heartbeat_checking_times_backoff = 1
      message_format_checking = disable
      upstream {
        topic = \"cp/${clientid}\"
        reply_topic = \"cp/${clientid}/Reply\"
        error_topic = \"cp/${clientid}/Reply\"
      }
      dnstream {
        topic = \"cs/${clientid}\"
      }
      listeners.ws.default {
          bind = \"0.0.0.0:33033\"
          websocket.path = \"/ocpp\"
      }
    }
">>).

all() -> emqx_common_test_helpers:all(?MODULE).

%%--------------------------------------------------------------------
%% setups
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    Apps = emqx_cth_suite:start(
        [
            {emqx_conf, ?CONF_DEFAULT},
            emqx_gateway_ocpp,
            emqx_gateway,
            emqx_auth,
            emqx_management,
            {emqx_dashboard, "dashboard.listeners.http { enable = true, bind = 18083 }"}
        ],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    emqx_common_test_http:create_default_app(),
    [{suite_apps, Apps} | Config].

end_per_suite(Config) ->
    emqx_common_test_http:delete_default_app(),
    emqx_cth_suite:stop(?config(suite_apps, Config)),
    ok.

init_per_testcase(_TestCase, Config) ->
    snabbkaffe:start_trace(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    snabbkaffe:stop(),
    ok.

default_config() ->
    ?CONF_DEFAULT.

update_ocpp_with_idle_timeout(IdleTimeout) ->
    Conf = emqx:get_raw_config([gateway, ocpp]),
    emqx_gateway_conf:update_gateway(
        ocpp,
        Conf#{<<"idle_timeout">> => IdleTimeout}
    ).

%%--------------------------------------------------------------------
%% cases
%%--------------------------------------------------------------------

t_update_listeners(_Config) ->
    {200, [DefaultListener]} = request(get, "/gateways/ocpp/listeners"),

    ListenerConfKeys =
        [
            id,
            type,
            name,
            enable,
            enable_authn,
            bind,
            acceptors,
            max_connections,
            max_conn_rate,
            proxy_protocol,
            proxy_protocol_timeout,
            websocket,
            tcp_options
        ],
    StatusKeys = [status, node_status],

    assert_fields_exist(ListenerConfKeys ++ StatusKeys, DefaultListener),
    ?assertMatch(
        #{
            id := <<"ocpp:ws:default">>,
            type := <<"ws">>,
            name := <<"default">>,
            enable := true,
            enable_authn := true,
            bind := <<"0.0.0.0:33033">>,
            websocket := #{path := <<"/ocpp">>}
        },
        DefaultListener
    ),

    UpdateBody = emqx_utils_maps:deep_put(
        [websocket, path],
        maps:with(ListenerConfKeys, DefaultListener),
        <<"/ocpp2">>
    ),
    {200, _} = request(put, "/gateways/ocpp/listeners/ocpp:ws:default", UpdateBody),

    {200, [UpdatedListener]} = request(get, "/gateways/ocpp/listeners"),
    ?assertMatch(#{websocket := #{path := <<"/ocpp2">>}}, UpdatedListener),

    %% update listener back to default
    UpdateBody2 = emqx_utils_maps:deep_put(
        [websocket, path],
        maps:with(ListenerConfKeys, DefaultListener),
        <<"/ocpp">>
    ),
    {200, _} = request(put, "/gateways/ocpp/listeners/ocpp:ws:default", UpdateBody2),

    {200, [UpdatedListener2]} = request(get, "/gateways/ocpp/listeners"),
    ?assertMatch(#{websocket := #{path := <<"/ocpp">>}}, UpdatedListener2),
    ok.

t_enable_disable_gw_ocpp(_Config) ->
    AssertEnabled = fun(Enabled) ->
        {200, R} = request(get, "/gateways/ocpp"),
        E = maps:get(enable, R),
        ?assertEqual(E, Enabled),
        timer:sleep(500),
        ?assertEqual(E, emqx:get_config([gateway, ocpp, enable]))
    end,
    ?assertEqual({204, #{}}, request(put, "/gateways/ocpp/enable/false", <<>>)),
    AssertEnabled(false),
    ?assertEqual({204, #{}}, request(put, "/gateways/ocpp/enable/true", <<>>)),
    AssertEnabled(true).

t_adjust_keepalive_timer(_Config) ->
    {ok, Client} = connect("127.0.0.1", 33033, <<"client1">>),
    UniqueId = <<"3335862321">>,
    BootNotification = #{
        id => UniqueId,
        type => ?OCPP_MSG_TYPE_ID_CALL,
        action => <<"BootNotification">>,
        payload => #{
            <<"chargePointVendor">> => <<"vendor1">>,
            <<"chargePointModel">> => <<"model1">>
        }
    },
    ok = send_msg(Client, BootNotification),
    %% check the default keepalive timer
    timer:sleep(1000),
    ?assertMatch(
        #{conninfo := #{keepalive := 60}}, emqx_gateway_cm:get_chan_info(ocpp, <<"client1">>)
    ),
    %% publish the BootNotification.ack
    AckPayload = emqx_utils_json:encode(#{
        <<"MessageTypeId">> => ?OCPP_MSG_TYPE_ID_CALLRESULT,
        <<"UniqueId">> => UniqueId,
        <<"Payload">> => #{
            <<"currentTime">> => "2023-06-21T14:20:39+00:00",
            <<"interval">> => 300,
            <<"status">> => <<"Accepted">>
        }
    }),
    _ = emqx:publish(emqx_message:make(<<"ocpp/cs/client1">>, AckPayload)),
    {ok, _Resp} = receive_msg(Client),
    %% assert: check the keepalive timer is adjusted
    ?assertMatch(
        #{conninfo := #{keepalive := 300}}, emqx_gateway_cm:get_chan_info(ocpp, <<"client1">>)
    ),
    %% close conns
    close(Client),
    timer:sleep(1000),
    %% assert:
    ?assertEqual(undefined, emqx_gateway_cm:get_chan_info(ocpp, <<"client1">>)),
    ok.

t_auth_expire(_Config) ->
    ok = meck:new(emqx_access_control, [passthrough, no_history]),
    ok = meck:expect(
        emqx_access_control,
        authenticate,
        fun(_) ->
            {ok, #{is_superuser => false, expire_at => erlang:system_time(millisecond) + 500}}
        end
    ),

    ?assertWaitEvent(
        {ok, _Client} = connect("127.0.0.1", 33033, <<"client1">>),
        #{
            ?snk_kind := conn_process_terminated,
            clientid := <<"client1">>,
            reason := {shutdown, expired}
        },
        5000
    ),

    meck:unload(emqx_access_control).

t_update_not_restart_listener(_Config) ->
    {ok, Client} = connect("127.0.0.1", 33033, <<"client1">>),
    %% update ocpp gateway config
    update_ocpp_with_idle_timeout(<<"20s">>),
    %% send BootNotification
    UniqueId = <<"3335862321">>,
    BootNotification = #{
        id => UniqueId,
        type => ?OCPP_MSG_TYPE_ID_CALL,
        action => <<"BootNotification">>,
        payload => #{
            <<"chargePointVendor">> => <<"vendor1">>,
            <<"chargePointModel">> => <<"model1">>
        }
    },
    ok = send_msg(Client, BootNotification),
    %% publish the BootNotification.ack
    AckPayload = emqx_utils_json:encode(#{
        <<"MessageTypeId">> => ?OCPP_MSG_TYPE_ID_CALLRESULT,
        <<"UniqueId">> => UniqueId,
        <<"Payload">> => #{
            <<"currentTime">> => "2023-06-21T14:20:39+00:00",
            <<"interval">> => 300,
            <<"status">> => <<"Accepted">>
        }
    }),
    _ = emqx:publish(emqx_message:make(<<"ocpp/cs/client1">>, AckPayload)),
    %% receive the BootNotification.ack
    {ok, _Resp} = receive_msg(Client),

    close(Client),
    ok.

t_listeners_status(_Config) ->
    {200, [Listener]} = request(get, "/gateways/ocpp/listeners"),
    ?assertMatch(
        #{
            status := #{running := true, current_connections := 0}
        },
        Listener
    ),
    %% add a connection
    {ok, Client} = connect("127.0.0.1", 33033, <<"client1">>),
    UniqueId = <<"3335862321">>,
    BootNotification = #{
        id => UniqueId,
        type => ?OCPP_MSG_TYPE_ID_CALL,
        action => <<"BootNotification">>,
        payload => #{
            <<"chargePointVendor">> => <<"vendor1">>,
            <<"chargePointModel">> => <<"model1">>
        }
    },
    ok = send_msg(Client, BootNotification),
    timer:sleep(1000),
    %% assert: the current_connections is 1
    {200, [Listener1]} = request(get, "/gateways/ocpp/listeners"),
    ?assertMatch(
        #{
            status := #{running := true, current_connections := 1}
        },
        Listener1
    ),
    %% close conns
    close(Client),
    timer:sleep(1000),
    %% assert: the current_connections is 0
    {200, [Listener2]} = request(get, "/gateways/ocpp/listeners"),
    ?assertMatch(
        #{
            status := #{running := true, current_connections := 0}
        },
        Listener2
    ).

%%--------------------------------------------------------------------
%% ocpp simple client

connect(Host, Port, ClientId) ->
    Timeout = 5000,
    ConnOpts = #{connect_timeout => 5000},
    case gun:open(Host, Port, ConnOpts) of
        {ok, ConnPid} ->
            {ok, _} = gun:await_up(ConnPid, Timeout),
            case upgrade(ConnPid, ClientId, Timeout) of
                {ok, StreamRef} -> {ok, {ConnPid, StreamRef}};
                Error -> Error
            end;
        Error ->
            Error
    end.

upgrade(ConnPid, ClientId, Timeout) ->
    Path = binary_to_list(<<"/ocpp/", ClientId/binary>>),
    WsHeaders = [{<<"cache-control">>, <<"no-cache">>}],
    StreamRef = gun:ws_upgrade(ConnPid, Path, WsHeaders, #{protocols => [{<<"ocpp1.6">>, gun_ws_h}]}),
    receive
        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers} ->
            {ok, StreamRef};
        {gun_response, ConnPid, _, _, Status, Headers} ->
            {error, {ws_upgrade_failed, Status, Headers}};
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {ws_upgrade_failed, Reason}}
    after Timeout ->
        {error, timeout}
    end.

send_msg({ConnPid, StreamRef}, Frame) when is_map(Frame) ->
    Opts = emqx_ocpp_frame:serialize_opts(),
    Msg = emqx_ocpp_frame:serialize_pkt(Frame, Opts),
    gun:ws_send(ConnPid, StreamRef, {text, Msg}).

receive_msg({ConnPid, StreamRef}) ->
    receive
        {gun_ws, ConnPid, StreamRef, {_Type, Msg}} ->
            ParseState = emqx_ocpp_frame:initial_parse_state(#{}),
            {ok, Frame, _Rest, _NewParseStaet} = emqx_ocpp_frame:parse(Msg, ParseState),
            {ok, Frame}
    after 5000 ->
        {error, {timeout, ?drainMailbox()}}
    end.

close({ConnPid, _StreamRef}) ->
    gun:shutdown(ConnPid).
