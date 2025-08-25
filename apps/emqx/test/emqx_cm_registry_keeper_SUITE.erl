%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_cm_registry_keeper_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include("emqx_cm.hrl").

-define(RETAIN_SECONS, 2).
%%--------------------------------------------------------------------
%% CT callbacks
%%--------------------------------------------------------------------

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    AppConfig = "broker.session_history_retain = " ++ integer_to_list(?RETAIN_SECONS) ++ "s",
    Apps = emqx_cth_suite:start(
        [{emqx, #{config => AppConfig}}],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    emqx_cth_suite:stop(proplists:get_value(apps, Config)).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

t_cleanup_after_retain(_) ->
    Pid = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    ClientId = <<"clientid">>,
    ClientId2 = <<"clientid2">>,
    emqx_cm_registry:register_channel({ClientId, Pid}),
    emqx_cm_registry:register_channel({ClientId2, Pid}),
    ?assertEqual([Pid], emqx_cm_registry:lookup_channels(ClientId)),
    ?assertEqual([Pid], emqx_cm_registry:lookup_channels(ClientId2)),
    ?assertEqual(2, emqx_cm_registry_keeper:count(0)),
    T0 = erlang:system_time(seconds),
    exit(Pid, kill),
    %% lookup_channels should not return dead pids
    ?assertEqual([], emqx_cm_registry:lookup_channels(ClientId)),
    ?assertEqual([], emqx_cm_registry:lookup_channels(ClientId2)),
    %% simulate a DOWN message triggering a clean up from emqx_cm
    ok = emqx_cm_registry:unregister_channel({ClientId, Pid}),
    ok = emqx_cm_registry:unregister_channel({ClientId2, Pid}),
    %% expect the channels to be eventually cleaned up after retain period
    ?retry(_Interval = 1000, _Attempts = 5, begin
        ?assertEqual(0, emqx_cm_registry_keeper:count(T0)),
        ?assertEqual(0, emqx_cm_registry_keeper:count(0))
    end),
    ok.

t_cleanup_chunk_interval(_) ->
    Pid = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    N = 201,
    ClientIds = lists:map(fun erlang:integer_to_binary/1, lists:seq(1, N)),
    Channels = lists:map(fun(ClientId) -> {ClientId, Pid} end, ClientIds),
    lists:foreach(fun emqx_cm_registry:register_channel/1, Channels),
    ?assertEqual(N, emqx_cm_registry:table_size()),
    exit(Pid, kill),
    lists:foreach(fun emqx_cm_registry:unregister_channel/1, Channels),
    ?retry(_Interval = 1000, _Attempts = 5, begin
        ?assertEqual(0, emqx_cm_registry:table_size())
    end),
    ok.

%% count is cached when the number of entries is greater than 1000
t_count_cache(_) ->
    Pid = self(),
    ClientsCount = 999,
    ClientIds = lists:map(fun erlang:integer_to_binary/1, lists:seq(1, ClientsCount)),
    Channels = lists:map(fun(ClientId) -> {ClientId, Pid} end, ClientIds),
    lists:foreach(
        fun emqx_cm_registry:register_channel/1,
        Channels
    ),
    T0 = erlang:system_time(seconds),
    ?assertEqual(ClientsCount, emqx_cm_registry_keeper:count(0)),
    ?assertEqual(ClientsCount, emqx_cm_registry_keeper:count(T0)),
    %% insert another one to trigger the cache threshold
    emqx_cm_registry:register_channel({<<"-1">>, Pid}),
    ?assertEqual(ClientsCount + 1, emqx_cm_registry_keeper:count(0)),
    ?assertEqual(ClientsCount, emqx_cm_registry_keeper:count(T0)),
    mnesia:clear_table(?CHAN_REG_TAB),
    ok.

channel(Id, Pid) ->
    #channel{chid = Id, pid = Pid}.
