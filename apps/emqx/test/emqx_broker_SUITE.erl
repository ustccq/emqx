%%--------------------------------------------------------------------
%% Copyright (c) 2018-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_broker_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("emqx/include/asserts.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_hooks.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").

all() ->
    [
        {group, all_cases},
        {group, connected_client_count_group}
    ].

groups() ->
    TCs = emqx_common_test_helpers:all(?MODULE),
    ConnClientTCs = [
        t_connected_client_count_persistent,
        t_connected_client_count_anonymous,
        t_connected_client_count_transient_takeover,
        t_connected_client_stats
    ],
    OtherTCs = TCs -- ConnClientTCs,
    [
        {all_cases, [], OtherTCs},
        {connected_client_count_group, [
            {group, tcp},
            {group, ws},
            {group, quic}
        ]},
        {tcp, [], ConnClientTCs},
        {ws, [], ConnClientTCs},
        {quic, [], ConnClientTCs}
    ].

init_per_group(connected_client_count_group, Config) ->
    Config;
init_per_group(tcp, Config) ->
    Apps = emqx_cth_suite:start(
        [emqx],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    [{conn_fun, connect}, {group_apps, Apps} | Config];
init_per_group(ws, Config) ->
    Apps = emqx_cth_suite:start(
        [emqx],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    [
        {ssl, false},
        {enable_websocket, true},
        {conn_fun, ws_connect},
        {port, 8083},
        {host, "localhost"},
        {group_apps, Apps}
        | Config
    ];
init_per_group(quic, Config) ->
    Apps = emqx_cth_suite:start(
        [
            {emqx,
                "listeners.quic.test {"
                "\n enable = true"
                "\n max_connections = 1024000"
                "\n idle_timeout = 15s"
                "\n ssl_options.verify = verify_peer"
                "\n }"}
        ],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    [
        {conn_fun, quic_connect},
        {port, emqx_config:get([listeners, quic, test, bind])},
        {ssl_opts, emqx_common_test_helpers:client_mtls()},
        {ssl, true},
        {group_apps, Apps}
        | Config
    ];
init_per_group(_Group, Config) ->
    Apps = emqx_cth_suite:start(
        [emqx],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    [{group_apps, Apps} | Config].

end_per_group(connected_client_count_group, _Config) ->
    ok;
end_per_group(_Group, Config) ->
    emqx_cth_suite:stop(?config(group_apps, Config)).

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    ?MODULE:Case({init, Config}).

end_per_testcase(Case, Config) ->
    ?MODULE:Case({'end', Config}).

%%--------------------------------------------------------------------
%% PubSub Test
%%--------------------------------------------------------------------

t_stats_fun({init, Config}) ->
    ok = emqx_stats:reset(),
    Config;
t_stats_fun(Config) when is_list(Config) ->
    ok = emqx_broker:subscribe(<<"topic">>, <<"clientid">>),
    ok = emqx_broker:subscribe(<<"topic2">>, <<"clientid">>),
    %% ensure stats refreshed
    emqx_broker_helper:stats_fun(),
    %% emqx_stats:set_stat is a gen_server cast
    %% make a synced call sync
    ignored = gen_server:call(emqx_stats, call, infinity),
    ?assertEqual(2, emqx_stats:getstat('subscribers.count')),
    ?assertEqual(2, emqx_stats:getstat('subscribers.max')),
    ?assertEqual(2, emqx_stats:getstat('subscriptions.count')),
    ?assertEqual(2, emqx_stats:getstat('subscriptions.max')),
    ?assertEqual(2, emqx_stats:getstat('suboptions.count')),
    ?assertEqual(2, emqx_stats:getstat('suboptions.max'));
t_stats_fun({'end', _Config}) ->
    ok = emqx_broker:unsubscribe(<<"topic">>),
    ok = emqx_broker:unsubscribe(<<"topic2">>).

t_subscribed({init, Config}) ->
    emqx_broker:subscribe(<<"topic">>),
    Config;
t_subscribed(Config) when is_list(Config) ->
    ?assertEqual(false, emqx_broker:subscribed(undefined, <<"topic">>)),
    ?assertEqual(true, emqx_broker:subscribed(self(), <<"topic">>));
t_subscribed({'end', _Config}) ->
    emqx_broker:unsubscribe(<<"topic">>).

t_subscribed_2({init, Config}) ->
    emqx_broker:subscribe(<<"topic">>, <<"clientid">>),
    Config;
t_subscribed_2(Config) when is_list(Config) ->
    ?assertEqual(true, emqx_broker:subscribed(self(), <<"topic">>));
t_subscribed_2({'end', _Config}) ->
    emqx_broker:unsubscribe(<<"topic">>).

t_subopts({init, Config}) ->
    Config;
t_subopts(Config) when is_list(Config) ->
    ?assertEqual(false, emqx_broker:set_subopts(<<"topic">>, #{qos => 1})),
    ?assertEqual(undefined, emqx_broker:get_subopts(self(), <<"topic">>)),
    ?assertEqual(undefined, emqx_broker:get_subopts(<<"clientid">>, <<"topic">>)),
    emqx_broker:subscribe(<<"topic">>, <<"clientid">>, #{qos => 1}),
    timer:sleep(200),
    ?assertEqual(
        #{nl => 0, qos => 1, rap => 0, rh => 0, subid => <<"clientid">>},
        emqx_broker:get_subopts(self(), <<"topic">>)
    ),
    ?assertEqual(
        #{nl => 0, qos => 1, rap => 0, rh => 0, subid => <<"clientid">>},
        emqx_broker:get_subopts(<<"clientid">>, <<"topic">>)
    ),

    emqx_broker:subscribe(<<"topic">>, <<"clientid">>, #{qos => 2}),
    ?assertEqual(
        #{nl => 0, qos => 2, rap => 0, rh => 0, subid => <<"clientid">>},
        emqx_broker:get_subopts(self(), <<"topic">>)
    ),

    ?assertEqual(true, emqx_broker:set_subopts(<<"topic">>, #{qos => 0})),
    ?assertEqual(
        #{nl => 0, qos => 0, rap => 0, rh => 0, subid => <<"clientid">>},
        emqx_broker:get_subopts(self(), <<"topic">>)
    );
t_subopts({'end', _Config}) ->
    emqx_broker:unsubscribe(<<"topic">>).

t_topics({init, Config}) ->
    Topics = [<<"topic">>, <<"topic/1">>, <<"topic/2">>],
    [{topics, Topics} | Config];
t_topics(Config) when is_list(Config) ->
    Topics = [T1, T2, T3] = proplists:get_value(topics, Config),
    ok = emqx_broker:subscribe(T1, <<"clientId">>),
    ok = emqx_broker:subscribe(T2, <<"clientId">>),
    ok = emqx_broker:subscribe(T3, <<"clientId">>),
    Topics1 = emqx_broker:topics(),
    ?assertEqual(
        true,
        lists:foldl(
            fun(Topic, Acc) ->
                case lists:member(Topic, Topics1) of
                    true -> Acc;
                    false -> false
                end
            end,
            true,
            Topics
        )
    );
t_topics({'end', Config}) ->
    Topics = proplists:get_value(topics, Config),
    lists:foreach(fun(T) -> emqx_broker:unsubscribe(T) end, Topics).

t_subscribers({init, Config}) ->
    emqx_broker:subscribe(<<"topic">>, <<"clientid">>),
    Config;
t_subscribers(Config) when is_list(Config) ->
    ?assertEqual([self()], emqx_broker:subscribers(<<"topic">>));
t_subscribers({'end', _Config}) ->
    emqx_broker:unsubscribe(<<"topic">>).

t_subscriptions({init, Config}) ->
    emqx_broker:subscribe(<<"topic">>, <<"clientid">>, #{qos => 1}),
    Config;
t_subscriptions(Config) when is_list(Config) ->
    ct:sleep(100),
    ?assertEqual(
        #{nl => 0, qos => 1, rap => 0, rh => 0, subid => <<"clientid">>},
        proplists:get_value(<<"topic">>, emqx_broker:subscriptions(self()))
    ),
    ?assertEqual(
        #{nl => 0, qos => 1, rap => 0, rh => 0, subid => <<"clientid">>},
        proplists:get_value(<<"topic">>, emqx_broker:subscriptions(<<"clientid">>))
    );
t_subscriptions({'end', _Config}) ->
    emqx_broker:unsubscribe(<<"topic">>).

t_sub_pub({init, Config}) ->
    ok = emqx_broker:subscribe(<<"topic">>),
    Config;
t_sub_pub(Config) when is_list(Config) ->
    ct:sleep(100),
    emqx_broker:safe_publish(emqx_message:make(ct, <<"topic">>, <<"hello">>)),
    ?assert(
        receive
            {deliver, <<"topic">>, #message{payload = <<"hello">>}} ->
                true;
            _ ->
                false
        after 100 ->
            false
        end
    );
t_sub_pub({'end', _Config}) ->
    ok = emqx_broker:unsubscribe(<<"topic">>).

t_nosub_pub({init, Config}) ->
    Config;
t_nosub_pub({'end', _Config}) ->
    ok;
t_nosub_pub(Config) when is_list(Config) ->
    ?assertEqual(0, emqx_metrics:val('messages.dropped')),
    emqx_broker:publish(emqx_message:make(ct, <<"topic">>, <<"hello">>)),
    ?assertEqual(1, emqx_metrics:val('messages.dropped')).

t_shared_subscribe({init, Config}) ->
    emqx_broker:subscribe(
        emqx_topic:make_shared_record(<<"group">>, <<"topic">>), <<"clientid">>, #{}
    ),
    ct:sleep(100),
    Config;
t_shared_subscribe(Config) when is_list(Config) ->
    emqx_broker:safe_publish(emqx_message:make(ct, <<"topic">>, <<"hello">>)),
    ?assert(
        receive
            {deliver, <<"topic">>, #message{
                headers = #{redispatch_to := ?REDISPATCH_TO(<<"group">>, <<"topic">>)},
                payload = <<"hello">>
            }} ->
                true;
            Msg ->
                ct:pal("Msg: ~p", [Msg]),
                false
        after 100 ->
            false
        end
    );
t_shared_subscribe({'end', _Config}) ->
    emqx_broker:unsubscribe(emqx_topic:make_shared_record(<<"group">>, <<"topic">>)).

t_shared_subscribe_2({init, Config}) ->
    Config;
t_shared_subscribe_2({'end', _Config}) ->
    ok;
t_shared_subscribe_2(_) ->
    {ok, ConnPid} = emqtt:start_link([{clean_start, true}, {clientid, <<"clientid">>}]),
    {ok, _} = emqtt:connect(ConnPid),
    {ok, _, [0]} = emqtt:subscribe(ConnPid, <<"$share/group/topic">>, 0),

    {ok, ConnPid2} = emqtt:start_link([{clean_start, true}, {clientid, <<"clientid2">>}]),
    {ok, _} = emqtt:connect(ConnPid2),
    {ok, _, [0]} = emqtt:subscribe(ConnPid2, <<"$share/group2/topic">>, 0),

    ct:sleep(10),
    ok = emqtt:publish(ConnPid, <<"topic">>, <<"hello">>, 0),
    Msgs = recv_msgs(2),
    ?assertEqual(2, length(Msgs)),
    ?assertEqual(
        true,
        lists:foldl(
            fun
                (#{payload := <<"hello">>, topic := <<"topic">>}, Acc) ->
                    Acc;
                (_, _) ->
                    false
            end,
            true,
            Msgs
        )
    ),
    emqtt:disconnect(ConnPid),
    emqtt:disconnect(ConnPid2).

t_shared_subscribe_3({init, Config}) ->
    Config;
t_shared_subscribe_3({'end', _Config}) ->
    ok;
t_shared_subscribe_3(_) ->
    {ok, ConnPid} = emqtt:start_link([{clean_start, true}, {clientid, <<"clientid">>}]),
    {ok, _} = emqtt:connect(ConnPid),
    {ok, _, [0]} = emqtt:subscribe(ConnPid, <<"$share/group/topic">>, 0),

    {ok, ConnPid2} = emqtt:start_link([{clean_start, true}, {clientid, <<"clientid2">>}]),
    {ok, _} = emqtt:connect(ConnPid2),
    {ok, _, [0]} = emqtt:subscribe(ConnPid2, <<"$share/group/topic">>, 0),

    ct:sleep(10),
    ok = emqtt:publish(ConnPid, <<"topic">>, <<"hello">>, 0),
    Msgs = recv_msgs(2),
    ?assertEqual(1, length(Msgs)),
    emqtt:disconnect(ConnPid),
    emqtt:disconnect(ConnPid2).

t_fanout({init, Config}) ->
    Config;
t_fanout({'end', _Config}) ->
    emqx_stats:reset();
t_fanout(_Config) ->
    NSubscribers = 2500,
    Subscribers = [
        spawn_link(fun() ->
            ClientID = integer_to_binary(I),
            ok = emqx_broker:subscribe(<<"topic">>, ClientID),
            ?assertReceive({deliver, <<"topic">>, #message{payload = <<"hello">>}}, 5000)
        end)
     || I <- lists:seq(1, NSubscribers)
    ],
    ?retry(
        200,
        10,
        NSubscribers = emqx_stats:getstat('suboptions.count')
    ),
    emqx_broker:safe_publish(emqx_message:make(ct, <<"topic">>, <<"hello">>)),
    ?retry(
        200,
        10,
        false = lists:any(fun erlang:is_process_alive/1, Subscribers)
    ).

t_fanout_async_dispatch({init, Config}) ->
    emqx_config:put([broker, perf, async_fanout_shard_dispatch], true),
    emqx_broker:init_config(),
    Config;
t_fanout_async_dispatch({'end', _Config}) ->
    emqx_config:put([broker, perf, async_fanout_shard_dispatch], false),
    emqx_broker:init_config();
t_fanout_async_dispatch(Config) ->
    t_fanout(Config).

%% persistent sessions, when gone, do not contribute to connected
%% client count
t_connected_client_count_persistent({init, Config}) ->
    ok = snabbkaffe:start_trace(),
    Config;
t_connected_client_count_persistent(Config) when is_list(Config) ->
    ConnFun = ?config(conn_fun, Config),
    ClientID = <<"clientid">>,
    ClientOpts = [
        {clean_start, false},
        {clientid, ClientID}
        | Config
    ],
    ?assertEqual(0, emqx_cm:get_connected_client_count()),
    ?check_trace(
        #{timetrap => 10_000},
        %% NOTE
        %% Change in the number of clients is sometimes not reflected immediately.
        %% That's why we have to retry test assertions.
        begin
            %% Connect a client.
            T0 = timestep(),
            {ok, ConnPid0} = emqtt:start_link(ClientOpts),
            {ok, _} = emqtt:ConnFun(ConnPid0),
            {ok, _} = block_until(emqx_cm_connected_client_count_inc, since(T0)),
            ?retry(10, 3, ?assertEqual(1, emqx_cm:get_connected_client_count())),
            %% Disconnect, should be zero again.
            true = erlang:unlink(ConnPid0),
            ok = emqtt:disconnect(ConnPid0),
            {ok, _} = block_until(emqx_cm_connected_client_count_dec, since(T0)),
            ?retry(10, 3, ?assertEqual(0, emqx_cm:get_connected_client_count())),
            %% Reconnecting.
            T1 = timestep(),
            {ok, ConnPid1} = emqtt:start_link(ClientOpts),
            {ok, _} = emqtt:ConnFun(ConnPid1),
            {ok, _} = block_until(emqx_cm_connected_client_count_inc, since(T1)),
            ?retry(10, 3, ?assertEqual(1, emqx_cm:get_connected_client_count())),
            %% Take over, should be exacly 1 once the takeover is complete.
            T2 = timestep(),
            true = erlang:unlink(ConnPid1),
            {ok, ConnPid2} = emqtt:start_link(ClientOpts),
            {ok, _} = emqtt:ConnFun(ConnPid2),
            {ok, _} = block_until(emqx_cm_connected_client_count_inc, since(T2)),
            {ok, _} = block_until(emqx_cm_connected_client_count_dec, since(T2)),
            ?retry(10, 3, ?assertEqual(1, emqx_cm:get_connected_client_count())),
            %% Abnormal exit of channel process
            T3 = timestep(),
            true = erlang:unlink(ConnPid2),
            ChanPids = emqx_cm:all_channels(),
            ok = lists:foreach(fun(ChanPid) -> exit(ChanPid, kill) end, ChanPids),
            {ok, _} = block_until(
                {
                    ?match_event(#{?snk_kind := emqx_cm_connected_client_count_dec}),
                    length(ChanPids)
                },
                since(T3)
            ),
            ?retry(10, 5, ?assertEqual(0, emqx_cm:get_connected_client_count()))
        end,
        fun(_) ->
            ok
        end
    );
t_connected_client_count_persistent({'end', _Config}) ->
    snabbkaffe:stop(),
    ok.

%% connections without client_id also contribute to connected client
%% count
t_connected_client_count_anonymous({init, Config}) ->
    ok = snabbkaffe:start_trace(),
    process_flag(trap_exit, true),
    Config;
t_connected_client_count_anonymous(Config) when is_list(Config) ->
    ConnFun = ?config(conn_fun, Config),
    ?assertEqual(0, emqx_cm:get_connected_client_count()),
    %% first client
    {ok, ConnPid0} = emqtt:start_link([
        {clean_start, true}
        | Config
    ]),
    {{ok, _}, {ok, [_]}} = wait_for_events(
        fun() -> emqtt:ConnFun(ConnPid0) end,
        [emqx_cm_connected_client_count_inc]
    ),
    ?assertEqual(1, emqx_cm:get_connected_client_count()),
    %% second client
    {ok, ConnPid1} = emqtt:start_link([
        {clean_start, true}
        | Config
    ]),
    {{ok, _}, {ok, [_]}} = wait_for_events(
        fun() -> emqtt:ConnFun(ConnPid1) end,
        [emqx_cm_connected_client_count_inc]
    ),
    ?assertEqual(2, emqx_cm:get_connected_client_count()),
    %% when first client disconnects, shouldn't affect the second
    {ok, {ok, [_]}} = wait_for_events(
        fun() -> emqtt:disconnect(ConnPid0) end,
        [
            emqx_cm_connected_client_count_dec
        ]
    ),
    ?assertEqual(1, emqx_cm:get_connected_client_count()),
    %% reconnecting
    {ok, ConnPid2} = emqtt:start_link([
        {clean_start, true}
        | Config
    ]),
    {{ok, _}, {ok, [_]}} = wait_for_events(
        fun() -> emqtt:ConnFun(ConnPid2) end,
        [emqx_cm_connected_client_count_inc]
    ),
    ?assertEqual(2, emqx_cm:get_connected_client_count()),
    {ok, {ok, [_]}} = wait_for_events(
        fun() -> emqtt:disconnect(ConnPid1) end,
        [
            emqx_cm_connected_client_count_dec
        ]
    ),
    ?assertEqual(1, emqx_cm:get_connected_client_count()),
    %% abnormal exit of channel process
    Chans = emqx_cm:all_channels(),
    {ok, {ok, [_]}} = wait_for_events(
        fun() ->
            lists:foreach(
                fun(ChanPid) -> exit(ChanPid, kill) end,
                Chans
            )
        end,
        [
            emqx_cm_connected_client_count_dec
        ]
    ),
    ?assertEqual(0, emqx_cm:get_connected_client_count()),
    ok;
t_connected_client_count_anonymous({'end', _Config}) ->
    snabbkaffe:stop(),
    ok.

t_connected_client_count_transient_takeover({init, Config}) ->
    ok = snabbkaffe:start_trace(),
    process_flag(trap_exit, true),
    Config;
t_connected_client_count_transient_takeover(Config) when is_list(Config) ->
    ConnFun = ?config(conn_fun, Config),
    ClientID = <<"clientid">>,
    ?assertEqual(0, emqx_cm:get_connected_client_count()),
    %% we spawn several clients simultaneously to cause the race
    %% condition for the client id lock
    NumClients = 20,
    ConnectSuccessCntr = counters:new(1, []),
    ConnectFailCntr = counters:new(1, []),
    ConnectFun =
        fun() ->
            process_flag(trap_exit, true),
            try
                {ok, ConnPid} =
                    emqtt:start_link([
                        {clean_start, true},
                        {clientid, ClientID}
                        | Config
                    ]),
                {ok, _} = emqtt:ConnFun(ConnPid),
                counters:add(ConnectSuccessCntr, 1, 1)
            catch
                _:_ ->
                    counters:add(ConnectFailCntr, 1, 1)
            end
        end,
    {ok, {ok, [_, _]}} =
        wait_for_events(
            fun() ->
                lists:foreach(
                    fun(_) ->
                        spawn(ConnectFun)
                    end,
                    lists:seq(1, NumClients)
                )
            end,
            %% At least one channel acquires the lock for this client id.  We
            %% also expect a decrement event because the client dies along with
            %% the ephemeral process.
            [
                emqx_cm_connected_client_count_inc,
                emqx_cm_connected_client_count_dec
            ],
            5000
        ),
    %% Since more than one pair of inc/dec may be emitted, we need to
    %% wait for full stabilization
    ?retry(
        _Sleep = 100,
        _Retries = 100,
        begin
            ConnectSuccessCnt = counters:get(ConnectSuccessCntr, 1),
            ConnectFailCnt = counters:get(ConnectFailCntr, 1),
            NumClients = ConnectSuccessCnt + ConnectFailCnt
        end
    ),
    ConnectSuccessCnt = counters:get(ConnectSuccessCntr, 1),
    ?assert(ConnectSuccessCnt > 0),
    EventsThatShouldHaveHappened = lists:flatten(
        lists:duplicate(
            ConnectSuccessCnt,
            [
                emqx_cm_connected_client_count_inc,
                emqx_cm_connected_client_count_dec
            ]
        )
    ),
    wait_for_events(fun() -> ok end, EventsThatShouldHaveHappened, 10000, infinity),
    %% It must be 0 again because we got enough
    %% emqx_cm_connected_client_count_dec events
    ?assertEqual(0, emqx_cm:get_connected_client_count()),
    %% connecting again
    {ok, ConnPid1} = emqtt:start_link([
        {clean_start, true},
        {clientid, ClientID}
        | Config
    ]),
    {{ok, _}, {ok, [_]}} =
        wait_for_events(
            fun() -> emqtt:ConnFun(ConnPid1) end,
            [emqx_cm_connected_client_count_inc],
            1000,
            1000
        ),
    ?assertEqual(1, emqx_cm:get_connected_client_count()),
    %% abnormal exit of channel process
    [ChanPid] = emqx_cm:all_channels(),
    {ok, {ok, [_]}} =
        wait_for_events(
            fun() ->
                exit(ChanPid, kill),
                ok
            end,
            [emqx_cm_connected_client_count_dec]
        ),
    ?assertEqual(0, emqx_cm:get_connected_client_count()),
    ok;
t_connected_client_count_transient_takeover({'end', _Config}) ->
    snabbkaffe:stop(),
    ok.

t_connected_client_stats({init, Config}) ->
    ok = supervisor:terminate_child(emqx_kernel_sup, emqx_stats),
    {ok, _} = supervisor:restart_child(emqx_kernel_sup, emqx_stats),
    ok = snabbkaffe:start_trace(),
    Config;
t_connected_client_stats(Config) when is_list(Config) ->
    ConnFun = ?config(conn_fun, Config),
    ?assertEqual(0, emqx_cm:get_connected_client_count()),
    ?assertEqual(0, emqx_stats:getstat('live_connections.count')),
    ?assertEqual(0, emqx_stats:getstat('live_connections.max')),
    {ok, ConnPid} = emqtt:start_link([
        {clean_start, true},
        {clientid, <<"clientid">>}
        | Config
    ]),
    {{ok, _}, {ok, [_]}} = wait_for_events(
        fun() -> emqtt:ConnFun(ConnPid) end,
        [emqx_cm_connected_client_count_inc]
    ),
    timer:sleep(20),
    %% ensure stats are synchronized
    {_, {ok, [_]}} = wait_for_stats(
        fun emqx_cm:stats_fun/0,
        [
            #{
                count_stat => 'live_connections.count',
                max_stat => 'live_connections.max'
            }
        ]
    ),
    ?assertEqual(1, emqx_stats:getstat('live_connections.count')),
    ?assertEqual(1, emqx_stats:getstat('live_connections.max')),
    {ok, {ok, [_]}} = wait_for_events(
        fun() -> emqtt:disconnect(ConnPid) end,
        [emqx_cm_connected_client_count_dec]
    ),
    timer:sleep(20),
    %% ensure stats are synchronized
    {_, {ok, [_]}} = wait_for_stats(
        fun emqx_cm:stats_fun/0,
        [
            #{
                count_stat => 'live_connections.count',
                max_stat => 'live_connections.max'
            }
        ]
    ),
    ?assertEqual(0, emqx_stats:getstat('live_connections.count')),
    ?assertEqual(1, emqx_stats:getstat('live_connections.max')),
    ok;
t_connected_client_stats({'end', _Config}) ->
    ok = snabbkaffe:stop(),
    ok = supervisor:terminate_child(emqx_kernel_sup, emqx_stats),
    {ok, _} = supervisor:restart_child(emqx_kernel_sup, emqx_stats),
    ok.

%% the count must be always non negative
t_connect_client_never_negative({init, Config}) ->
    Config;
t_connect_client_never_negative(Config) when is_list(Config) ->
    ?assertEqual(0, emqx_cm:get_connected_client_count()),
    %% would go to -1
    ChanPid = list_to_pid("<0.0.1>"),
    emqx_cm:mark_channel_disconnected(ChanPid),
    ?assertEqual(0, emqx_cm:get_connected_client_count()),
    %% would be 0, if really went to -1
    emqx_cm:mark_channel_connected(ChanPid),
    ?assertEqual(1, emqx_cm:get_connected_client_count()),
    ok;
t_connect_client_never_negative({'end', _Config}) ->
    ok.

t_connack_auth_error({init, Config}) ->
    process_flag(trap_exit, true),
    emqx_hooks:put(
        'client.authenticate',
        {?MODULE, authenticate_deny, []},
        ?HP_AUTHN
    ),
    Config;
t_connack_auth_error({'end', _Config}) ->
    emqx_hooks:del(
        'client.authenticate',
        {?MODULE, authenticate_deny, []}
    ),
    ok;
t_connack_auth_error(Config) when is_list(Config) ->
    %% MQTT 3.1
    ?assertEqual(0, emqx_metrics:val('packets.connack.auth_error')),
    {ok, C0} = emqtt:start_link([{proto_ver, v4}]),
    ?assertEqual({error, {malformed_username_or_password, undefined}}, emqtt:connect(C0)),
    ?assertEqual(1, emqx_metrics:val('packets.connack.auth_error')),
    %% MQTT 5.0
    {ok, C1} = emqtt:start_link([{proto_ver, v5}]),
    ?assertEqual({error, {bad_username_or_password, #{}}}, emqtt:connect(C1)),
    ?assertEqual(2, emqx_metrics:val('packets.connack.auth_error')),
    ok.

authenticate_deny(_Credentials, _Default) ->
    {stop, {error, bad_username_or_password}}.

wait_for_events(Action, Kinds) ->
    wait_for_events(Action, Kinds, 1000).

wait_for_events(Action, Kinds, Timeout) ->
    wait_for_events(Action, Kinds, Timeout, 0).

wait_for_events(Action, Kinds, Timeout, BackInTime) ->
    Predicate = fun(#{?snk_kind := K}) ->
        lists:member(K, Kinds)
    end,
    N = length(Kinds),
    {ok, Sub} = snabbkaffe_collector:subscribe(Predicate, N, Timeout, BackInTime),
    Res = Action(),
    case snabbkaffe_collector:receive_events(Sub) of
        {timeout, _} ->
            {Res, timeout};
        {ok, Events} ->
            {Res, {ok, Events}}
    end.

block_until(Kind, BackInTime) when is_atom(Kind) ->
    block_until(?match_event(#{?snk_kind := Kind}), BackInTime);
block_until(Predicate, BackInTime) ->
    snabbkaffe:block_until(Predicate, infinity, BackInTime).

wait_for_stats(Action, Stats) ->
    Predicate = fun
        (Event = #{?snk_kind := emqx_stats_setstat}) ->
            Stat = maps:with(
                [
                    count_stat,
                    max_stat
                ],
                Event
            ),
            lists:member(Stat, Stats);
        (_) ->
            false
    end,
    N = length(Stats),
    Timeout = 500,
    {ok, Sub} = snabbkaffe_collector:subscribe(Predicate, N, Timeout, 0),
    Res = Action(),
    case snabbkaffe_collector:receive_events(Sub) of
        {timeout, _} ->
            {Res, timeout};
        {ok, Events} ->
            {Res, {ok, Events}}
    end.

recv_msgs(Count) ->
    recv_msgs(Count, []).

recv_msgs(0, Msgs) ->
    Msgs;
recv_msgs(Count, Msgs) ->
    receive
        {publish, Msg} ->
            recv_msgs(Count - 1, [Msg | Msgs]);
        _Other ->
            recv_msgs(Count, Msgs)
    after 100 ->
        Msgs
    end.

timestep() ->
    T0 = erlang:monotonic_time(millisecond),
    ok = timer:sleep(1),
    T0.

since(T0) ->
    erlang:monotonic_time(millisecond) - T0.
