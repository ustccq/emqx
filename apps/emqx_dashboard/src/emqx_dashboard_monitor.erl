%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_dashboard_monitor).

-include("emqx_dashboard.hrl").

-include_lib("snabbkaffe/include/trace.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-behaviour(gen_server).

-export([create_tables/0, clear_table/0]).
-export([start_link/0]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2,
    terminate/2,
    code_change/3
]).

-export([
    samplers/0,
    samplers/2,
    current_rate/1
]).

%% for rpc
-export([do_sample/2]).

%% For tests
-export([
    current_rate_cluster/0,
    sample_interval/1,
    store/1,
    format/1,
    clean/1,
    lookup/1,
    sample_nodes/2,
    randomize/2,
    randomize/3,
    sample_fill_gap/2,
    fill_gaps/2,
    all_data/0
]).

%% For testing
-export([
    merge_current_rate_cluster/1
]).

-define(TAB, ?MODULE).

-define(ONE_SECOND, 1_000).
-define(SECONDS, ?ONE_SECOND).
-define(ONE_MINUTE, 60 * ?SECONDS).
-define(MINUTES, ?ONE_MINUTE).
-define(ONE_HOUR, 60 * ?MINUTES).
-define(HOURS, ?ONE_HOUR).
-define(ONE_DAY, 24 * ?HOURS).
-define(DAYS, ?ONE_DAY).

-define(CLEAN_EXPIRED_INTERVAL, 10 * ?MINUTES).
-define(RETENTION_TIME, 7 * ?DAYS).
-define(MAX_POSSIBLE_SAMPLES, 1440).
-define(LOG(LEVEL, DATA), ?SLOG(LEVEL, DATA, #{tag => "DASHBOARD"})).
-define(NO_WMARK, no_wmark).
-define(HWMARK(T, P, V), {T, P, V}).
-define(MAYBE_HWMARK(Condition, Hwmark),
    case Condition of
        true -> Hwmark;
        false -> ?NO_WMARK
    end
).

-record(emqx_monit, {
    time :: integer(),
    data :: map()
}).

-record(state, {
    last :: #emqx_monit{},
    clean_timer :: undefined | reference(),
    extra = []
}).

create_tables() ->
    ok = mria:create_table(?TAB, [
        {type, set},
        {local_content, true},
        {storage, disc_copies},
        {record_name, emqx_monit},
        {attributes, record_info(fields, emqx_monit)}
    ]),
    [?TAB].

clear_table() ->
    mria:clear_table(?TAB).

%% -------------------------------------------------------------------------------------------------
%% API

samplers() ->
    format(sample_fill_gap(all, 0)).

samplers(NodeOrCluster, Latest) ->
    SinceTime = latest2time(Latest),
    case format(sample_fill_gap(NodeOrCluster, SinceTime)) of
        {badrpc, Reason} ->
            {badrpc, Reason};
        List when is_list(List) ->
            List
    end.

latest2time(infinity) -> 0;
latest2time(Latest) -> now_ts() - (Latest * 1000).

current_rate(all) ->
    current_rate_cluster();
current_rate(Node) when Node == node() ->
    try
        do_call(current_rate)
    catch
        _E:R:Stacktrace ->
            ?LOG(warning, #{msg => "dashboard_monitor_error", reason => R, stacktrace => Stacktrace}),
            %% Rate map 0, ensure api will not crash.
            %% When joining cluster, dashboard monitor restart.
            Rate0 = [
                {Key, 0}
             || Key <- ?GAUGE_SAMPLER_LIST ++ maps:values(?DELTA_SAMPLER_RATE_MAP)
            ],
            {ok, maps:merge(maps:from_list(Rate0), non_rate_value())}
    end;
current_rate(Node) ->
    case emqx_dashboard_proto_v2:current_rate(Node) of
        {badrpc, Reason} ->
            {badrpc, #{node => Node, reason => Reason}};
        {ok, Rate} ->
            {ok, Rate}
    end.

%% Get the current rate. Not the current sampler data.
current_rate_cluster() ->
    Nodes = mria:cluster_nodes(running),
    %% each call has 5s timeout, so it's ok to wait infinity here
    L0 = emqx_utils:pmap(fun(Node) -> current_rate(Node) end, Nodes, infinity),
    {L1, Failed} = lists:partition(
        fun
            ({ok, _}) -> true;
            (_) -> false
        end,
        L0
    ),
    Failed =/= [] andalso
        ?LOG(badrpc_log_level(L1), #{msg => "failed_to_sample_current_rate", errors => Failed}),
    Metrics = merge_current_rate_cluster(L1),
    {ok, adjust_synthetic_cluster_metrics(Metrics)}.

merge_current_rate_cluster(L1) ->
    Fun = fun({ok, Result}, Cluster) -> merge_cluster_rate(Result, Cluster) end,
    lists:foldl(Fun, #{}, L1).

%% -------------------------------------------------------------------------------------------------
%% gen_server functions

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ok = start_sample_timer(),
    Dummy = #emqx_monit{time = now_ts(), data = #{}},
    {ok, #state{last = Dummy, clean_timer = undefined, extra = []}, {continue, initial_cleanup}}.

handle_continue(initial_cleanup, State) ->
    ok = clean(),
    ok = inplace_downsample(),
    {noreply, State#state{clean_timer = start_clean_timer()}, {continue, read_hwmark}};
handle_continue(read_hwmark, State) ->
    %% this is silly, but the table type is set to `set`, not `ordered_set`
    %% so we need to sort the list by time and get the latest one
    case all_data() of
        [] ->
            {noreply, State};
        List ->
            {Time, Data} = lists:last(List),
            {noreply, State#state{last = #emqx_monit{time = Time, data = Data}}}
    end.

handle_call(current_rate, _From, State = #state{last = Last}) ->
    NowTime = now_ts(),
    NowSamplers = take_sample(NowTime, Last, read_hwmark),
    Rate = cal_rate(NowSamplers, Last),
    NonRateValue = non_rate_value(),
    Result1 = maps:merge(Rate, NonRateValue),
    Result = format_hwmarks(Result1, NowSamplers),
    {reply, {ok, Result}, State};
handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info({sample, Time}, State = #state{last = Last}) ->
    Now = take_sample(Time, Last, write_hwmark),
    {atomic, ok} = flush(Last, Now),
    ?tp(dashboard_monitor_flushed, #{}),
    ok = start_sample_timer(),
    {noreply, State#state{last = Now}};
handle_info(clean_expired, #state{clean_timer = TrefOld} = State) ->
    ok = maybe_cancel_timer(TrefOld),
    ok = clean(),
    ok = inplace_downsample(),
    TrefNew = start_clean_timer(),
    {noreply, State#state{clean_timer = TrefNew}};
handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

%% -------------------------------------------------------------------------------------------------
%% Internal functions

-spec all_data() -> [{integer(), map()}].
all_data() ->
    all_data(fun(_) -> true end, sort).

-spec all_data(fun((integer()) -> boolean()), sort | no_sort) -> [{integer(), map()}].
all_data(Pred, Sort) ->
    Fn = fun(#emqx_monit{time = Time, data = Data}, Acc) ->
        case Pred(Time) of
            true -> [{Time, Data} | Acc];
            false -> Acc
        end
    end,
    All = ets:foldl(Fn, [], ?TAB),
    case Sort of
        sort ->
            lists:keysort(1, All);
        no_sort ->
            All
    end.

inplace_downsample() ->
    All = all_data(),
    Now = now_ts(),
    Compacted = compact(Now, All),
    {Deletes, Writes} = compare(All, Compacted, [], []),
    {atomic, ok} = mria:transaction(
        mria:local_content_shard(),
        fun() ->
            lists:foreach(
                fun(T) ->
                    mnesia:delete(?TAB, T, write)
                end,
                Deletes
            ),
            lists:foreach(
                fun({T, D}) ->
                    mnesia:write(?TAB, #emqx_monit{time = T, data = D}, write)
                end,
                Writes
            )
        end
    ),
    ok.

%% compare the original data points with the compacted data points
%% return the timestamps to be deleted and the new data points to be written
compare(Remain, [], Deletes, Writes) ->
    %% all compacted buckets have been processed, remaining datapoints should all be deleted
    RemainTsList = lists:map(fun({T, _Data}) -> T end, Remain),
    {Deletes ++ RemainTsList, Writes};
compare([{T, Data} | All], [{T, Data} | Compacted], Deletes, Writes) ->
    %% no change, do nothing
    compare(All, Compacted, Deletes, Writes);
compare([{T, _} | All], [{T, Data} | Compacted], Deletes, Writes) ->
    %% this timetamp has been compacted away, but overwrite it with new data
    compare(All, Compacted, Deletes, [{T, Data} | Writes]);
compare([{T0, _} | All], [{T1, _} | _] = Compacted, Deletes, Writes) when T0 < T1 ->
    %% this timstamp has been compacted away, delete it
    compare(All, Compacted, [T0 | Deletes], Writes);
compare([{T0, _} | _] = All, [{T1, Data1} | Compacted], Deletes, Writes) when T0 > T1 ->
    %% compare with the next compacted bucket timestamp
    compare(All, Compacted, Deletes, [{T1, Data1} | Writes]).

%% compact the data points to a smaller set of buckets
%% Pre-condition: data fed to this function must be sorted chronologically.
compact(Now, Data) ->
    compact(Now, Data, []).

compact(_Now, [], Acc) ->
    lists:reverse(Acc);
compact(Now, [{Time, Data} | Rest], Acc) ->
    Interval = sample_interval(Now - Time),
    Bucket = round_down(Time, Interval),
    NewAcc = merge_to_bucket(Bucket, Data, Acc),
    compact(Now, Rest, NewAcc).

merge_to_bucket(Bucket, Data, [{Bucket, Data0} | Acc]) ->
    NewData = merge_local_sampler_maps(Data0, Data),
    [{Bucket, NewData} | Acc];
merge_to_bucket(Bucket, Data, Acc) ->
    [{Bucket, Data} | Acc].

%% for testing
randomize(Count, Data) when is_map(Data) ->
    MaxAge = 7 * ?DAYS,
    randomize(Count, Data, MaxAge).

randomize(Count, Data, Age) when is_map(Data) andalso is_integer(Age) ->
    Now = now_ts() - 1,
    StartTs = Now - Age,
    lists:foreach(
        fun(_) ->
            Ts = round_down(StartTs + rand:uniform(Age), timer:seconds(10)),
            Record = #emqx_monit{time = Ts, data = Data},
            case ets:lookup(?TAB, Ts) of
                [] ->
                    store(Record);
                [#emqx_monit{data = D} = R] ->
                    store(R#emqx_monit{data = merge_local_sampler_maps(Data, D)})
            end
        end,
        lists:seq(1, Count)
    ).

maybe_cancel_timer(Tref) when is_reference(Tref) ->
    _ = erlang:cancel_timer(Tref),
    ok;
maybe_cancel_timer(_) ->
    ok.

do_call(Request) ->
    gen_server:call(?MODULE, Request, 5000).

do_sample(Node, infinity) ->
    %% handle RPC from old version nodes
    do_sample(Node, 0);
do_sample(all, Time) when is_integer(Time) ->
    AllNodes = emqx:running_nodes(),
    All = sample_nodes(AllNodes, Time),
    maps:map(fun(_, S) -> adjust_synthetic_cluster_metrics(S) end, All);
do_sample(Node, Time) when Node == node() andalso is_integer(Time) ->
    do_sample_local(Time);
do_sample(Node, Time) when is_integer(Time) ->
    case emqx_dashboard_proto_v2:do_sample(Node, Time) of
        {badrpc, Reason} ->
            {badrpc, #{node => Node, reason => Reason}};
        Res ->
            Res
    end.

do_sample_local(Time) ->
    MS = ets:fun2ms(fun(#emqx_monit{time = T} = A) when T >= Time -> A end),
    FromDB = ets:select(?TAB, MS),
    Map = to_ts_data_map(FromDB),
    %% downsample before return RPC calls for less data to merge by the caller nodes
    downsample_local(Time, Map).

%% log error level when there is no success (unlikely to happen), and warning otherwise
badrpc_log_level([]) -> error;
badrpc_log_level(_) -> warning.

sample_nodes(Nodes, Time) ->
    ResList = concurrently_sample_nodes(Nodes, Time),
    {Failed, Success} = lists:partition(
        fun
            ({badrpc, _}) -> true;
            (_) -> false
        end,
        ResList
    ),
    Failed =/= [] andalso
        ?LOG(badrpc_log_level(Success), #{msg => "failed_to_sample_monitor_data", errors => Failed}),
    lists:foldl(fun(I, B) -> merge_samplers(Time, I, B) end, #{}, Success).

concurrently_sample_nodes(Nodes, Time) ->
    %% emqx_dashboard_proto_v2:do_sample has a timeout (5s),
    %% call emqx_utils:pmap here instead of a rpc multicall
    %% to avoid having to introduce a new bpapi proto version
    emqx_utils:pmap(fun(Node) -> do_sample(Node, Time) end, Nodes, infinity).

merge_samplers(SinceTime, Increment0, Base) ->
    Increment =
        case map_size(Increment0) > ?MAX_POSSIBLE_SAMPLES of
            true ->
                %% this is a response from older version node
                downsample(SinceTime, Increment0);
            false ->
                Increment0
        end,
    maps:fold(fun merge_samplers_loop/3, Base, Increment).

merge_samplers_loop(Ts, Increment, Base) when is_map(Increment) ->
    case maps:get(Ts, Base, undefined) of
        undefined ->
            Base#{Ts => Increment};
        BaseSample when is_map(BaseSample) ->
            Base#{Ts => merge_sampler_maps(Increment, BaseSample)}
    end.

merge_sampler_maps(M1, M2) when is_map(M1) andalso is_map(M2) ->
    Fun = fun(Key, Acc) -> merge_values(Key, M1, Acc) end,
    lists:foldl(Fun, M2, ?SAMPLER_LIST).

%% `M1' is assumed to be newer data compared to anything `M2' has seen.
merge_local_sampler_maps(M1, M2) when is_map(M1) andalso is_map(M2) ->
    Fun = fun(Key, Acc) -> merge_local_values(Key, M1, Acc) end,
    lists:foldl(Fun, M2, ?SAMPLER_LIST).

%% topics, subscriptions_durable and disconnected_durable_sessions are cluster synced
merge_values(topics, M1, M2) ->
    max_values(topics, M1, M2);
merge_values(subscriptions_durable, M1, M2) ->
    max_values(subscriptions_durable, M1, M2);
merge_values(disconnected_durable_sessions, M1, M2) ->
    max_values(disconnected_durable_sessions, M1, M2);
merge_values(Key, M1, M2) ->
    sum_values(Key, M1, M2).

merge_local_values(Key, M1, M2) when ?IS_PICK_NEWER(Key) ->
    %% First argument is assumed to be from a newer timestamp, so we keep the latest.
    M2#{Key => maps:get(Key, M1, maps:get(Key, M2, 0))};
merge_local_values(Key, M1, M2) ->
    merge_values(Key, M1, M2).

max_values(Key, M1, M2) when is_map_key(Key, M1) orelse is_map_key(Key, M2) ->
    M2#{Key => max(maps:get(Key, M1, 0), maps:get(Key, M2, 0))};
max_values(_Key, _M1, M2) ->
    M2.

sum_values(Key, M1, M2) when is_map_key(Key, M1) orelse is_map_key(Key, M2) ->
    M2#{Key => maps:get(Key, M1, 0) + maps:get(Key, M2, 0)};
sum_values(_Key, _M1, M2) ->
    M2.

merge_cluster_rate(Node, Cluster) ->
    Fun =
        fun
            %% cluster-synced values
            (disconnected_durable_sessions, V, NCluster) ->
                NCluster#{disconnected_durable_sessions => V};
            (subscriptions_durable, V, NCluster) ->
                NCluster#{subscriptions_durable => V};
            (topics, V, NCluster) ->
                NCluster#{topics => V};
            (retained_msg_count, V, NCluster) ->
                NCluster#{retained_msg_count => V};
            (shared_subscriptions, V, NCluster) ->
                NCluster#{shared_subscriptions => V};
            (license_quota, V, NCluster) ->
                NCluster#{license_quota => V};
            (sessions_hist_hwmark, V, NCluster) ->
                max_hwmark(sessions_hist_hwmark, V, NCluster);
            %% for cluster sample, ignore node_uptime
            (node_uptime, _V, NCluster) ->
                NCluster;
            (Key, Value, NCluster) ->
                ClusterValue = maps:get(Key, NCluster, 0),
                NCluster#{Key => Value + ClusterValue}
        end,
    maps:fold(Fun, Cluster, Node).

adjust_synthetic_cluster_metrics(Metrics0) ->
    DSSubs = maps:get(subscriptions_durable, Metrics0, 0),
    RamSubs = maps:get(subscriptions, Metrics0, 0),
    DisconnectedDSs = maps:get(disconnected_durable_sessions, Metrics0, 0),
    Metrics1 = maps:update_with(
        subscriptions,
        fun(Subs) -> Subs + DSSubs end,
        0,
        Metrics0
    ),
    Metrics = maps:put(subscriptions_ram, RamSubs, Metrics1),
    maps:update_with(
        connections,
        fun(RamConns) -> RamConns + DisconnectedDSs end,
        DisconnectedDSs,
        Metrics
    ).

format({badrpc, Reason}) ->
    {badrpc, Reason};
format(Data0) ->
    Data1 = maps:to_list(Data0),
    Data = lists:keysort(1, Data1),
    lists:map(fun({TimeStamp, V}) -> V#{time_stamp => TimeStamp} end, Data).

cal_rate(
    #emqx_monit{data = NowData, time = NowTime},
    #emqx_monit{data = LastData, time = LastTime}
) ->
    TimeDelta = NowTime - LastTime,
    Filter = fun(Key, _) -> lists:member(Key, ?GAUGE_SAMPLER_LIST) end,
    Gauge = maps:filter(Filter, NowData),
    {_, _, _, Rate} =
        lists:foldl(
            fun cal_rate_/2,
            {NowData, LastData, TimeDelta, Gauge},
            ?DELTA_SAMPLER_LIST
        ),
    Rate.

cal_rate_(Key, {Now, Last, TDelta, Res}) ->
    NewValue = maps:get(Key, Now),
    LastValue = maps:get(Key, Last, 0),
    %% round up time delta to 1s, and value data to non-negative
    %% 1. never divide by zero, or result in unreasonably high rate.
    %% 2. never return negative rate.
    Rate = round(max(NewValue - LastValue, 0) * 1000 / max(TDelta, 1000)),
    RateKey = maps:get(Key, ?DELTA_SAMPLER_RATE_MAP),
    {Now, Last, TDelta, Res#{RateKey => Rate}}.

%% Try to keep the total number of recrods around 1000.
%% When the oldest data point is
%% < 1h: sample every 10s: 360 data points
%% < 1d: sample every 1m: 1440 data points
%% < 3d: sample every 5m: 864 data points
%% < 7d: sample every 10m: 1008 data points
sample_interval(Age) when Age =< 60 * ?SECONDS ->
    ?ONE_SECOND;
sample_interval(Age) when Age =< ?ONE_HOUR ->
    10 * ?SECONDS;
sample_interval(Age) when Age =< ?ONE_DAY ->
    ?ONE_MINUTE;
sample_interval(Age) when Age =< 3 * ?DAYS ->
    5 * ?MINUTES;
sample_interval(_Age) ->
    10 * ?MINUTES.

sample_fill_gap(Node, SinceTs) ->
    %% make a remote call so it can be mocked for testing
    Samples = ?MODULE:do_sample(Node, SinceTs),
    fill_gaps(Samples, SinceTs).

fill_gaps({badrpc, _} = BadRpc, _) ->
    BadRpc;
fill_gaps(Samples, SinceTs) when is_map(Samples) ->
    TsList = ts_list(Samples),
    case length(TsList) >= 2 of
        true ->
            do_fill_gaps(hd(TsList), tl(TsList), Samples, SinceTs);
        false ->
            Samples
    end.

do_fill_gaps(FirstTs, TsList, Samples, SinceTs) ->
    Latest = lists:last(TsList),
    Interval = sample_interval(Latest - SinceTs),
    StartTs =
        case round_down(SinceTs, Interval) of
            T when T =:= 0 orelse T =:= FirstTs ->
                FirstTs;
            T ->
                T
        end,
    fill_gaps_loop(StartTs, Interval, Latest, Samples).

fill_gaps_loop(T, _Interval, Latest, Samples) when T >= Latest ->
    Samples;
fill_gaps_loop(T, Interval, Latest, Samples) ->
    Samples1 =
        case is_map_key(T, Samples) of
            true ->
                Samples;
            false ->
                Samples#{T => #{}}
        end,
    fill_gaps_loop(T + Interval, Interval, Latest, Samples1).

downsample(SinceTs, TsDataMap) when map_size(TsDataMap) >= 2 ->
    TsList = ts_list(TsDataMap),
    Latest = lists:max(TsList),
    Interval = sample_interval(Latest - SinceTs),
    downsample_loop(TsList, TsDataMap, Interval, #{});
downsample(_Since, TsDataMap) ->
    TsDataMap.

downsample_local(SinceTs, TsDataMap) when map_size(TsDataMap) >= 2 ->
    TsList = ts_list(TsDataMap),
    Latest = lists:max(TsList),
    Interval = sample_interval(Latest - SinceTs),
    downsample_local_loop(TsList, TsDataMap, Interval, #{});
downsample_local(_Since, TsDataMap) ->
    TsDataMap.

ts_list(TsDataMap) ->
    lists:sort(maps:keys(TsDataMap)).

round_down(Ts, Interval) ->
    Ts - (Ts rem Interval).

downsample_loop([], _TsDataMap, _Interval, Res) ->
    Res;
downsample_loop([Ts | Rest], TsDataMap, Interval, Res) ->
    Bucket = round_down(Ts, Interval),
    Agg0 = maps:get(Bucket, Res, #{}),
    Inc = maps:get(Ts, TsDataMap),
    Agg = merge_sampler_maps(Inc, Agg0),
    downsample_loop(Rest, TsDataMap, Interval, Res#{Bucket => Agg}).

downsample_local_loop([], _TsDataMap, _Interval, Res) ->
    Res;
downsample_local_loop([Ts | Rest], TsDataMap, Interval, Res) ->
    Bucket = round_down(Ts, Interval),
    Agg0 = maps:get(Bucket, Res, #{}),
    Inc = maps:get(Ts, TsDataMap),
    Agg = merge_local_sampler_maps(Inc, Agg0),
    downsample_local_loop(Rest, TsDataMap, Interval, Res#{Bucket => Agg}).

%% timer

start_sample_timer() ->
    {NextTime, Remaining} = next_interval(),
    _ = erlang:send_after(Remaining, self(), {sample, NextTime}),
    ok.

start_clean_timer() ->
    erlang:send_after(?CLEAN_EXPIRED_INTERVAL, self(), clean_expired).

%% Per interval seconds.
%% As an example:
%%  Interval = 10
%%  The monitor will start working at full seconds, as like 00:00:00, 00:00:10, 00:00:20 ...
%% Ensure that the monitor data of all nodes in the cluster are aligned in time
next_interval() ->
    Interval = emqx_conf:get([dashboard, sample_interval], ?DEFAULT_SAMPLE_INTERVAL) * 1000,
    Now = now_ts(),
    NextTime = round_down(Now, Interval) + Interval,
    Remaining = NextTime - Now,
    {NextTime, Remaining}.

%% -------------------------------------------------------------------------------------------------
%% data

take_sample(Time, LastHwmark, ReadOrWrite) ->
    Fun =
        fun(Key, Acc) ->
            Acc#{Key => getstats(Key)}
        end,
    Data0 = lists:foldl(Fun, #{}, ?SAMPLER_LIST),
    Data =
        case ReadOrWrite of
            read_hwmark ->
                last_hwmark(LastHwmark, Data0);
            write_hwmark ->
                refresh_hwmark(Time, LastHwmark, Data0)
        end,
    #emqx_monit{time = Time, data = Data}.

%% Take hwmark data from the last sample.
last_hwmark(#emqx_monit{data = LastHwmarks}, Data) ->
    lists:foldl(
        fun(Key, Acc) ->
            case ?MAYBE_HWMARK(is_map_key(Key, LastHwmarks), maps:get(Key, LastHwmarks)) of
                ?HWMARK(_, _, _) = Hwmark ->
                    Acc#{Key => Hwmark};
                _ ->
                    Acc
            end
        end,
        Data,
        ?WATERMARK_SAMPLER_LIST
    ).

%% Refresh the hwmark data, prepare for writing to the database.
refresh_hwmark(Time, #emqx_monit{data = LastHwmarks}, Data) ->
    lists:foldl(
        fun(Key, Acc) ->
            Current = current_wmark(Key),
            case Current =:= ?NO_WMARK of
                true ->
                    %% no hwmark for this key, e.g. disabled, ignore it
                    Acc;
                false ->
                    Old = ?MAYBE_HWMARK(is_map_key(Key, LastHwmarks), maps:get(Key, LastHwmarks)),
                    New = ?MAYBE_HWMARK(Current =/= ?NO_WMARK, ?HWMARK(Time, Current, Current)),
                    Hwmark = do_refresh_hwmark(Key, Old, New),
                    Acc#{Key => Hwmark}
            end
        end,
        Data,
        ?WATERMARK_SAMPLER_LIST
    ).

current_wmark(sessions_hist_hwmark) ->
    case emqx_cm_registry:is_hist_enabled() of
        true -> emqx_cm_registry:table_size();
        false -> ?NO_WMARK
    end.

do_refresh_hwmark(
    Key,
    ?HWMARK(TPast, PPast, _VPast),
    ?HWMARK(TNow, _PNow, VNow)
) when VNow < PPast ->
    %% Lower than peak, check if the peak is expired.
    RetentionTime = emqx_conf:get([dashboard, hwmark_expire_time]),
    ExpireAt = TNow - RetentionTime,
    case TPast =< ExpireAt of
        true ->
            %% the old high watermark is expired,
            %% scan the data since TPast to find the new peak time and value.
            %% this needs to read all records from the database, but hopefully this is not so frequent.
            All = all_data(fun(T) -> T > ExpireAt end, no_sort),
            {PT, PV} = scan_hwmark(Key, All, TNow, VNow),
            ?HWMARK(PT, PV, VNow);
        false ->
            %% keep the old peak time and value.
            ?HWMARK(TPast, PPast, VNow)
    end;
do_refresh_hwmark(_Key, _Past, ?HWMARK(_, _, _) = Now) ->
    Now.

scan_hwmark(_Key, [], T, V) ->
    {T, V};
scan_hwmark(Key, [{T0, Data} | Rest], T, V) ->
    case maps:get(Key, Data, ?NO_WMARK) of
        ?HWMARK(_, _, V0) when (V0 > V) orelse (V0 =:= V andalso T0 > T) ->
            scan_hwmark(Key, Rest, T0, V0);
        _ ->
            scan_hwmark(Key, Rest, T, V)
    end.

flush(#emqx_monit{data = LastData}, Now = #emqx_monit{data = NowData}) ->
    Store = Now#emqx_monit{data = delta(LastData, NowData)},
    store(Store).

delta(LastData, NowData) ->
    Fun =
        fun(Key, Data) ->
            Value = maps:get(Key, NowData) - maps:get(Key, LastData, 0),
            Data#{Key => Value}
        end,
    lists:foldl(Fun, NowData, ?DELTA_SAMPLER_LIST).

lookup(Ts) ->
    ets:lookup(?TAB, Ts).

store(MonitData) ->
    {atomic, ok} =
        mria:transaction(mria:local_content_shard(), fun mnesia:write/3, [?TAB, MonitData, write]).

clean() ->
    clean(?RETENTION_TIME).

clean(Retention) ->
    Now = now_ts(),
    MS = ets:fun2ms(fun(#emqx_monit{time = T}) when Now - T > Retention -> T end),
    TsList = ets:select(?TAB, MS),
    {atomic, ok} =
        mria:transaction(
            mria:local_content_shard(),
            fun() ->
                lists:foreach(
                    fun(T) ->
                        mnesia:delete(?TAB, T, write)
                    end,
                    TsList
                )
            end
        ),
    ok.

%% This data structure should not be changed because it's a RPC contract.
%% Otherwise dashboard may not work during rolling upgrade.
to_ts_data_map(List) when is_list(List) ->
    Fun =
        fun(#emqx_monit{time = Time, data = Data}, All) ->
            All#{Time => Data}
        end,
    lists:foldl(Fun, #{}, List).

getstats(Key) ->
    %% Stats ets maybe not exist when ekka join.
    try
        stats(Key)
    catch
        _:_ -> 0
    end.

stats(connections) ->
    emqx_stats:getstat('connections.count');
stats(disconnected_durable_sessions) ->
    emqx_persistent_session_bookkeeper:get_disconnected_session_count();
stats(subscriptions_durable) ->
    emqx_stats:getstat('durable_subscriptions.count');
stats(live_connections) ->
    emqx_stats:getstat('live_connections.count');
stats(cluster_sessions) ->
    emqx_stats:getstat('cluster_sessions.count');
stats(topics) ->
    emqx_stats:getstat('topics.count');
stats(subscriptions) ->
    emqx_stats:getstat('subscriptions.count');
stats(shared_subscriptions) ->
    emqx_stats:getstat('subscriptions.shared.count');
stats(retained_msg_count) ->
    emqx_stats:getstat('retained.count');
stats(received) ->
    emqx_metrics:val('messages.received');
stats(received_bytes) ->
    emqx_metrics:val('bytes.received');
stats(sent) ->
    emqx_metrics:val('messages.sent');
stats(sent_bytes) ->
    emqx_metrics:val('bytes.sent');
stats(validation_succeeded) ->
    emqx_metrics:val('messages.validation_succeeded');
stats(validation_failed) ->
    emqx_metrics:val('messages.validation_failed');
stats(transformation_succeeded) ->
    emqx_metrics:val('messages.transformation_succeeded');
stats(transformation_failed) ->
    emqx_metrics:val('messages.transformation_failed');
stats(dropped) ->
    emqx_metrics:val('messages.dropped');
stats(persisted) ->
    emqx_metrics:val('messages.persisted').

%% -------------------------------------------------------------------------------------------------
%% Retained && License Quota

%% the non rate values should be same on all nodes
non_rate_value() ->
    (license_quota())#{
        retained_msg_count => stats(retained_msg_count),
        shared_subscriptions => stats(shared_subscriptions),
        node_uptime => emqx_sys:uptime()
    }.

license_quota() ->
    case emqx_license_checker:limits() of
        {ok, #{max_sessions := Quota}} ->
            #{license_quota => Quota};
        {error, no_license} ->
            #{license_quota => 0}
    end.

now_ts() ->
    erlang:system_time(millisecond).

%% make hwmark data JSON serializable.
format_hwmarks(Result, #emqx_monit{data = Samplers}) ->
    lists:foldl(
        fun(Key, Acc) ->
            case maps:get(Key, Samplers, ?NO_WMARK) of
                ?HWMARK(T, P, V) ->
                    Acc#{Key => #{peak_time => T, peak_value => P, current_value => V}};
                _ ->
                    Acc
            end
        end,
        Result,
        ?WATERMARK_SAMPLER_LIST
    ).

%% High watermarks are sampled on all nodes in different pace,
%% we pick the max value from all nodes.
max_hwmark(Key, ThisNode, Cluster) when not is_map_key(Key, Cluster) ->
    Cluster#{Key => ThisNode};
max_hwmark(Key, #{peak_time := T, peak_value := V} = ThisNode, Cluster) ->
    #{peak_time := ClusterPT, peak_value := ClusterPV} = OtherNode = maps:get(Key, Cluster),
    case V > ClusterPV orelse (V =:= ClusterPV andalso T > ClusterPT) of
        true ->
            Cluster#{Key => ThisNode};
        false ->
            Cluster#{Key => OtherNode}
    end.
