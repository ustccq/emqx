%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_metrics_worker).

-behaviour(gen_server).

-include_lib("stdlib/include/ms_transform.hrl").

%% API functions
-export([
    start_link/1,
    start_link/2,
    stop/1,
    child_spec/1,
    child_spec/2,
    child_spec/3
]).

-export([
    inc/3,
    inc/4,
    observe/4,
    observe_hist/4,
    get/3,
    set/4,
    get_gauge/3,
    set_gauge/5,
    shift_gauge/5,
    get_gauges/2,
    delete_gauges/2,
    get_rate/2,
    get_slide/2,
    get_slide/3,
    get_hists/2,
    get_counters/2,
    create_metrics/3,
    create_metrics/4,
    ensure_metrics/4,
    clear_metrics/2,
    reset_metrics/2,
    has_metrics/2
]).

-export([get_metrics/2]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_info/2,
    handle_cast/2,
    code_change/3,
    terminate/2
]).

-ifndef(TEST).
-define(SECS_5M, 300).
-define(SAMPLING, 10).
-else.
%% Use 5 secs average rate instead of 5 mins in case of testing
-define(SECS_5M, 5).
-define(SAMPLING, 1).
-endif.

%% By default, we suppose that the histograms are used for latency measurement
%% with millisecond precision.
%% We provide the buckets corresponding to the intervals:
%% =<10ms, =<100ms, =<1s, =<5s, =<30s, >30s
-define(DEFAULT_HIST_BUCKETS, [10, 100, 1000, 5000, 30000]).

-export_type([metrics/0, handler_name/0, metric_id/0, metric_spec/0]).

-type handler_name() :: atom().
%% metric_id() is actually a resource id
-type metric_id() :: binary() | atom().
-type metric_name() :: atom().
-type worker_id() :: term().

-type hist_bucket_spec() :: [non_neg_integer()].

-type metric_full_spec() ::
    {counter, metric_name()}
    | {gauge, metric_name()}
    | {slide, metric_name()}
    | {hist, metric_name(), hist_bucket_spec()}.

-type metric_spec() ::
    metric_full_spec()
    %% counter
    | metric_name()
    %% histogram with default buckets
    | {hist, metric_name()}.

-type hist() :: #{
    buckets := hist_bucket_spec(),
    counts := [non_neg_integer()]
}.

-type rate() :: #{
    current := float(),
    max := float(),
    last5m := float()
}.
-type metrics() :: #{
    counters := #{metric_name() => integer()},
    gauges := #{metric_name() => integer()},
    slides := #{metric_name() => number()},
    hists := #{metric_name() => hist()},
    rate := #{metric_name() => rate()}
}.

-type init_metrics() ::
    [{metric_id(), [metric_spec()], [metric_name()]}]
    | [{metric_id(), [metric_spec()]}].

-define(CntrRef(Name), {?MODULE, Name}).
-define(SAMPCOUNT_5M, (?SECS_5M div ?SAMPLING)).
-define(GAUGE_TABLE(NAME),
    list_to_atom(atom_to_list(?MODULE) ++ "_" ++ atom_to_list(NAME) ++ "_gauge")
).

-record(rate, {
    max = 0 :: number(),
    current = 0 :: number(),
    last5m = 0 :: number(),
    %% metadata for calculating the avg rate
    tick = 1 :: number(),
    last_v = 0 :: number(),
    %% metadata for calculating the 5min avg rate
    last5m_acc = 0 :: number(),
    last5m_smpl = [] :: list()
}).

-record(slide_datapoint, {
    sum :: non_neg_integer(),
    samples :: non_neg_integer(),
    time :: non_neg_integer()
}).

-record(slide, {
    %% Total number of samples through the history
    n_samples = 0 :: non_neg_integer(),
    datapoints = [] :: [#slide_datapoint{}]
}).

-record(hist, {
    buckets :: [non_neg_integer()]
}).

-record(state, {
    name :: handler_name(),
    metric_ids = sets:new([{version, 2}]),
    rates :: #{metric_id() => #{metric_name() => #rate{}}} | undefined,
    slides = #{} :: #{metric_id() => #{metric_name() => #slide{}}},
    hists = #{} :: #{metric_id() => #{metric_name() => #hist{}}}
}).

%% calls/casts/infos
-record(ensure_metrics, {
    id :: metric_id(),
    metrics :: [metric_full_spec()],
    rate_metrics :: [metric_name()]
}).
-record(create_metrics, {
    id :: metric_id(),
    metrics :: [metric_full_spec()],
    rate_metrics :: [metric_name()]
}).
-record(delete_metrics, {id :: metric_id()}).
-record(reset_metrics, {id :: metric_id()}).
-record(get_rate, {id :: metric_id()}).
-record(get_slide, {id :: metric_id(), window = undefined :: non_neg_integer() | undefined}).
-record(get_hists, {id :: metric_id()}).

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

-spec child_spec(handler_name()) -> supervisor:child_spec().
child_spec(Name) ->
    child_spec(emqx_metrics_worker, Name, []).

-spec child_spec(_ChildId :: term(), handler_name()) -> supervisor:child_spec().
child_spec(ChldName, Name) ->
    child_spec(ChldName, Name, []).

-spec child_spec(_ChildId :: term(), handler_name(), init_metrics()) ->
    supervisor:child_spec().
child_spec(ChldName, Name, InitMetrics0) ->
    InitMetrics = normalize_initial_metrics(InitMetrics0),
    #{
        id => ChldName,
        start => {emqx_metrics_worker, start_link, [Name, InitMetrics]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [emqx_metrics_worker]
    }.

-spec create_metrics(handler_name(), metric_id(), [metric_spec()]) ->
    ok | {error, term()}.
create_metrics(Name, Id, Metrics) ->
    Metrics1 = desugar(Metrics),
    RateMetrics = filter_counters(Metrics1),
    create_metrics(Name, Id, Metrics1, RateMetrics).

-spec create_metrics(handler_name(), metric_id(), [metric_spec()], [metric_name()]) ->
    ok | {error, term()}.
create_metrics(Name, Id, Metrics, RateMetrics) ->
    Metrics1 = desugar(Metrics),
    gen_server:call(
        Name,
        #create_metrics{id = Id, metrics = Metrics1, rate_metrics = RateMetrics}
    ).

-spec ensure_metrics(handler_name(), metric_id(), [metric_spec()], [metric_name()]) ->
    {ok, created | already_created} | {error, term()}.
ensure_metrics(Name, Id, Metrics0, RateMetrics) ->
    Metrics = desugar(Metrics0),
    gen_server:call(
        Name,
        #ensure_metrics{id = Id, metrics = Metrics, rate_metrics = RateMetrics},
        infinity
    ).

-spec clear_metrics(handler_name(), metric_id()) -> ok.
clear_metrics(Name, Id) ->
    gen_server:call(Name, #delete_metrics{id = Id}).

-spec reset_metrics(handler_name(), metric_id()) -> ok.
reset_metrics(Name, Id) ->
    gen_server:call(Name, #reset_metrics{id = Id}).

-spec has_metrics(handler_name(), metric_id()) -> boolean().
has_metrics(Name, Id) ->
    case get_ref(Name, Id) of
        not_found -> false;
        _ -> true
    end.

-spec get(handler_name(), metric_id(), metric_name() | integer()) -> number().
get(Name, Id, Metric) ->
    case get_ref(Name, Id) of
        not_found ->
            0;
        Ref when is_atom(Metric) ->
            counters:get(Ref, idx_metric(Name, Id, counter, Metric));
        Ref when is_integer(Metric) ->
            counters:get(Ref, Metric)
    end.

-spec get_rate(handler_name(), metric_id()) -> map().
get_rate(Name, Id) ->
    gen_server:call(Name, #get_rate{id = Id}).

-spec get_counters(handler_name(), metric_id()) -> map().
get_counters(Name, Id) ->
    maps:map(
        fun(_Metric, Index) ->
            get(Name, Id, Index)
        end,
        get_indexes(Name, counter, Id)
    ).

-spec get_slide(handler_name(), metric_id()) -> map().
get_slide(Name, Id) ->
    gen_server:call(Name, #get_slide{id = Id}).

%% Get the average for a specified sliding window period.
%%
%% It will only account for the samples recorded in the past `Window' seconds.
-spec get_slide(handler_name(), metric_id(), non_neg_integer()) -> number().
get_slide(Name, Id, Window) ->
    gen_server:call(Name, #get_slide{id = Id, window = Window}).

%% Get the incremental counters for each histogram bucket together with the
%% total count and the sum of observations.
-spec get_hists(handler_name(), metric_id()) -> map().
get_hists(Name, Id) ->
    gen_server:call(Name, #get_hists{id = Id}).

-spec reset_counters(handler_name(), metric_id()) -> ok.
reset_counters(Name, Id) ->
    case get_ref(Name, Id) of
        not_found ->
            ok;
        Ref ->
            #{size := Size} = counters:info(Ref),
            lists:foreach(fun(Idx) -> counters:put(Ref, Idx, 0) end, lists:seq(1, Size))
    end.

-spec get_metrics(handler_name(), metric_id()) -> metrics().
get_metrics(Name, Id) ->
    #{
        rate => get_rate(Name, Id),
        counters => get_counters(Name, Id),
        gauges => get_gauges(Name, Id),
        slides => get_slide(Name, Id),
        hists => get_hists(Name, Id)
    }.

-spec inc(handler_name(), metric_id(), atom()) -> ok.
inc(Name, Id, Metric) ->
    inc(Name, Id, Metric, 1).

-spec inc(handler_name(), metric_id(), metric_name(), integer()) -> ok.
inc(Name, Id, Metric, Val) ->
    counters:add(get_ref(Name, Id), idx_metric(Name, Id, counter, Metric), Val).

%% Set value of counter explicitly, so it can behave as a gauge.
-spec set(handler_name(), metric_id(), metric_name(), integer()) -> ok.
set(Name, Id, Metric, Val) ->
    counters:put(get_ref(Name, Id), idx_metric(Name, Id, counter, Metric), Val).

%% Add a sample to the slide.
%%
%% Slide is short for "sliding window average" type of metric.
%%
%% It allows to monitor an average of some observed values in time,
%% and it's mainly used for performance analysis. For example, it can
%% be used to report run time of operations.
%%
%% Consider an example:
%%
%% ```
%% emqx_metrics_worker:create_metrics(Name, Id, [{slide, a}]),
%% emqx_metrics_worker:observe(Name, Id, a, 10),
%% emqx_metrics_worker:observe(Name, Id, a, 30),
%% #{a := 20} = emqx_metrics_worker:get_slide(Name, Id, _Window = 1).
%% '''
%%
%% After recording 2 samples, this metric becomes 20 (the average of 10 and 30).
%%
%% But after 1 second it becomes 0 again, unless new samples are recorded.
%%
-spec observe(handler_name(), metric_id(), atom(), integer()) -> ok.
observe(Name, Id, Metric, Val) ->
    #{Id := #{ref := CRef, slide := #{Metric := Index}}} = get_pterm(Name),
    %% Update sum:
    counters:add(CRef, Index, Val),
    %% Update number of samples:
    counters:add(CRef, Index + 1, 1).

-spec observe_hist(handler_name(), metric_id(), atom(), integer()) -> ok.
observe_hist(Name, Id, Metric, Val) ->
    #{Id := #{ref := CRef, hist := #{Metric := {Index, Buckets}}}} = get_pterm(Name),
    %% Update sum:
    counters:add(CRef, Index, Val),
    %% Update bucket counter:
    update_hist_bucket(CRef, Index + 1, Buckets, Val).

update_hist_bucket(CRef, Index, [Bucket | _Rest], Val) when Val =< Bucket ->
    counters:add(CRef, Index, 1);
%% +Inf bucket
update_hist_bucket(CRef, Index, [], _Val) ->
    counters:add(CRef, Index, 1);
update_hist_bucket(CRef, Index, [_Bucket | Rest], Val) ->
    update_hist_bucket(CRef, Index + 1, Rest, Val).

-spec set_gauge(handler_name(), metric_id(), worker_id(), metric_name(), integer()) -> ok.
set_gauge(Name, Id, WorkerId, Metric, Val) ->
    Table = ?GAUGE_TABLE(Name),
    try
        true = ets:insert(Table, {{Id, Metric, WorkerId}, Val}),
        ok
    catch
        error:badarg ->
            ok
    end.

-spec shift_gauge(handler_name(), metric_id(), worker_id(), metric_name(), integer()) -> ok.
shift_gauge(Name, Id, WorkerId, Metric, Val) ->
    Table = ?GAUGE_TABLE(Name),
    try
        _ = ets:update_counter(
            Table,
            {Id, Metric, WorkerId},
            Val,
            {{Id, Metric, WorkerId}, 0}
        ),
        ok
    catch
        error:badarg ->
            ok
    end.

-spec get_gauge(handler_name(), metric_id(), metric_name()) -> integer().
get_gauge(Name, Id, Metric) ->
    Table = ?GAUGE_TABLE(Name),
    MatchSpec =
        ets:fun2ms(
            fun({{Id0, Metric0, _WorkerId}, Val}) when Id0 =:= Id, Metric0 =:= Metric ->
                Val
            end
        ),
    try
        lists:sum(ets:select(Table, MatchSpec))
    catch
        error:badarg ->
            0
    end.

-spec get_gauges(handler_name(), metric_id()) -> map().
get_gauges(Name, Id) ->
    Table = ?GAUGE_TABLE(Name),
    MatchSpec =
        ets:fun2ms(
            fun({{Id0, Metric, _WorkerId}, Val}) when Id0 =:= Id ->
                {Metric, Val}
            end
        ),
    try
        lists:foldr(
            fun({Metric, Val}, Acc) ->
                maps:update_with(Metric, fun(X) -> X + Val end, Val, Acc)
            end,
            #{},
            ets:select(Table, MatchSpec)
        )
    catch
        error:badarg ->
            #{}
    end.

-spec delete_gauges(handler_name(), metric_id()) -> ok.
delete_gauges(Name, Id) ->
    Table = ?GAUGE_TABLE(Name),
    MatchSpec =
        ets:fun2ms(
            fun({{Id0, _Metric, _WorkerId}, _Val}) when Id0 =:= Id ->
                true
            end
        ),
    try
        _ = ets:select_delete(Table, MatchSpec),
        ok
    catch
        error:badarg ->
            ok
    end.

-spec start_link(handler_name()) -> gen_server:start_ret().
start_link(Name) ->
    start_link(Name, []).

-spec start_link(handler_name(), init_metrics()) -> gen_server:start_ret().
start_link(Name, InitMetrics) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, InitMetrics}, []).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init({Name, InitMetrics}) ->
    erlang:process_flag(trap_exit, true),
    %% the rate metrics
    erlang:send_after(timer:seconds(?SAMPLING), self(), ticking),
    persistent_term:put(?CntrRef(Name), #{}),
    _ = ets:new(?GAUGE_TABLE(Name), [named_table, ordered_set, public, {write_concurrency, true}]),
    case handle_create_initial_metrics(#state{name = Name}, InitMetrics) of
        {ok, State} ->
            {ok, State};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(#get_rate{id = _Id}, _From, State = #state{rates = undefined}) ->
    {reply, make_rate(0, 0, 0), State};
handle_call(#get_rate{id = Id}, _From, State = #state{rates = Rates}) ->
    {reply,
        case maps:get(Id, Rates, undefined) of
            undefined -> make_rate(0, 0, 0);
            RatesPerId -> format_rates_of_id(RatesPerId)
        end, State};
handle_call(#create_metrics{id = Id, metrics = Metrics, rate_metrics = RateMetrics}, _From, State0) ->
    {Result, State} = handle_create_metrics(State0, Id, Metrics, RateMetrics),
    {reply, Result, State};
handle_call(#ensure_metrics{id = Id, metrics = Metrics, rate_metrics = RateMetrics}, _From, State0) ->
    {Result, State} = handle_ensure_metrics(State0, Id, Metrics, RateMetrics),
    {reply, Result, State};
handle_call(
    #delete_metrics{id = Id},
    _From,
    State = #state{name = Name, metric_ids = MIDs, rates = Rates, slides = Slides, hists = Hists}
) ->
    delete_counters(Name, Id),
    delete_gauges(Name, Id),
    {reply, ok, State#state{
        metric_ids = sets:del_element(Id, MIDs),
        rates =
            case Rates of
                undefined -> undefined;
                _ -> maps:remove(Id, Rates)
            end,
        slides = maps:remove(Id, Slides),
        hists = maps:remove(Id, Hists)
    }};
handle_call(
    #reset_metrics{id = Id},
    _From,
    State = #state{name = Name, rates = Rates, slides = Slides, hists = Hists}
) ->
    delete_gauges(Name, Id),
    NewRates =
        case Rates of
            undefined ->
                undefined;
            _ ->
                ResetRate =
                    maps:map(
                        fun(_Key, _Value) -> #rate{} end,
                        maps:get(Id, Rates, #{})
                    ),
                maps:put(Id, ResetRate, Rates)
        end,
    SlideSpecs = [{slide, I} || I <- maps:keys(maps:get(Id, Slides, #{}))],
    NewSlides = Slides#{Id => create_slides(SlideSpecs)},
    HistsSpecs = [
        {hist, I, Buckets}
     || {I, #hist{buckets = Buckets}} <- maps:to_list(maps:get(Id, Hists, #{}))
    ],
    NewHists = Hists#{Id => create_hists(HistsSpecs)},
    {reply, reset_counters(Name, Id), State#state{
        rates =
            NewRates,
        slides = NewSlides,
        hists = NewHists
    }};
handle_call(
    #get_slide{id = Id, window = undefined}, _From, State = #state{name = Name, slides = Slides}
) ->
    SlidesForID = maps:get(Id, Slides, #{}),
    {reply, maps:map(fun(Metric, Slide) -> do_get_slide(Name, Id, Metric, Slide) end, SlidesForID),
        State};
handle_call(
    #get_slide{id = Id, window = Window}, _From, State = #state{name = Name, slides = Slides}
) ->
    SlidesForID = maps:get(Id, Slides, #{}),
    {reply,
        maps:map(
            fun(Metric, Slide) -> do_get_slide(Name, Window, Id, Metric, Slide) end, SlidesForID
        ),
        State};
handle_call(#get_hists{id = Id}, _From, State = #state{name = Name, hists = Hists}) ->
    HistsForID = maps:get(Id, Hists, #{}),
    {reply, maps:map(fun(Metric, Hist) -> do_get_hist(Name, Id, Metric, Hist) end, HistsForID),
        State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(ticking, State = #state{rates = undefined}) ->
    erlang:send_after(timer:seconds(?SAMPLING), self(), ticking),
    {noreply, State};
handle_info(ticking, State = #state{name = Name, rates = Rates0, slides = Slides0}) ->
    Rates =
        maps:map(
            fun(Id, RatesPerId) ->
                maps:map(
                    fun(Metric, Rate) ->
                        calculate_rate(get(Name, Id, Metric), Rate)
                    end,
                    RatesPerId
                )
            end,
            Rates0
        ),
    Slides =
        maps:map(
            fun(Id, SlidesPerID) ->
                maps:map(
                    fun(Metric, Slide) ->
                        update_slide(Name, Id, Metric, Slide)
                    end,
                    SlidesPerID
                )
            end,
            Slides0
        ),
    erlang:send_after(timer:seconds(?SAMPLING), self(), ticking),
    {noreply, State#state{rates = Rates, slides = Slides}};
handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{name = Name, metric_ids = MIDs}) ->
    [delete_counters(Name, Id) || Id <- sets:to_list(MIDs)],
    persistent_term:erase(?CntrRef(Name)).

stop(Name) ->
    try
        gen_server:stop(Name, normal, 10000)
    catch
        exit:noproc ->
            ok;
        exit:timeout ->
            %% after timeout, the process killed by gen.erl
            ok
    end.

%%------------------------------------------------------------------------------
%% Internal Functions
%%------------------------------------------------------------------------------

create_counters(_Name, _Id, []) ->
    {error, {create_counter_error, must_provide_a_list_of_metrics}};
create_counters(Name, Id, Metrics) ->
    %% backup the old counters
    OlderCounters = maps:with(filter_counters(Metrics), get_counters(Name, Id)),
    %% create the new counter
    {Size, Indexes} = create_metric_indexes(Metrics),
    Counters = get_pterm(Name),
    CntrRef = counters:new(Size, [write_concurrency]),
    persistent_term:put(
        ?CntrRef(Name),
        Counters#{Id => Indexes#{ref => CntrRef}}
    ),
    %% Restore the old counters. Slides/histograms are not restored,
    %% Slides are periodically zeroed anyway. We do lose some samples in the
    %% current interval, but that's acceptable for now.
    %% Histograms may change buckets; also is considered the histogram
    %% consumer's responsibility to handle zeroing (like Prometheus does).
    lists:foreach(
        fun({Metric, N}) ->
            inc(Name, Id, Metric, N)
        end,
        maps:to_list(OlderCounters)
    ).

%% TODO
%% better acc
create_metric_indexes(Metrics) ->
    create_metric_indexes(Metrics, 1, [], [], []).

create_metric_indexes([], Size, Counters, Slides, Hists) ->
    {Size, #{
        counter => maps:from_list(Counters),
        slide => maps:from_list(Slides),
        hist => maps:from_list(Hists)
    }};
create_metric_indexes([{counter, Id} | Rest], Index, Counters, Slides, Hists) ->
    create_metric_indexes(Rest, Index + 1, [{Id, Index} | Counters], Slides, Hists);
create_metric_indexes([{slide, Id} | Rest], Index, Counters, Slides, Hists) ->
    create_metric_indexes(Rest, Index + 2, Counters, [{Id, Index} | Slides], Hists);
create_metric_indexes([{hist, Id, Buckets} | Rest], Index, Counters, Slides, Hists) ->
    %% For histogram, we need 2 additional indexes:
    %% * one for the +Inf bucket
    %% * one for the total sum of observations
    create_metric_indexes(Rest, Index + length(Buckets) + 2, Counters, Slides, [
        {Id, {Index, Buckets}} | Hists
    ]).

delete_counters(Name, Id) ->
    persistent_term:put(?CntrRef(Name), maps:remove(Id, get_pterm(Name))).

get_ref(Name, Id) ->
    case maps:find(Id, get_pterm(Name)) of
        {ok, #{ref := Ref}} -> Ref;
        error -> not_found
    end.

idx_metric(Name, Id, Type, Metric) ->
    maps:get(Metric, get_indexes(Name, Type, Id)).

get_indexes(Name, Type, Id) ->
    case maps:get(Id, get_pterm(Name), #{}) of
        #{Type := Indexes} -> Indexes;
        #{} -> #{}
    end.

get_pterm(Name) ->
    persistent_term:get(?CntrRef(Name), #{}).

calculate_rate(_CurrVal, undefined) ->
    undefined;
calculate_rate(CurrVal, #rate{
    max = MaxRate0,
    last_v = LastVal,
    tick = Tick,
    last5m_acc = AccRate5Min0,
    last5m_smpl = Last5MinSamples0
}) ->
    %% calculate the current rate based on the last value of the counter
    CurrRate = (CurrVal - LastVal) / ?SAMPLING,

    %% calculate the max rate since the emqx startup
    MaxRate =
        case MaxRate0 >= CurrRate of
            true -> MaxRate0;
            false -> CurrRate
        end,

    %% calculate the average rate in last 5 mins
    {Last5MinSamples, Acc5Min, Last5Min} =
        case Tick =< ?SAMPCOUNT_5M of
            true ->
                Acc = AccRate5Min0 + CurrRate,
                {lists:reverse([CurrRate | lists:reverse(Last5MinSamples0)]), Acc, Acc / Tick};
            false ->
                [FirstRate | Rates] = Last5MinSamples0,
                Acc = AccRate5Min0 + CurrRate - FirstRate,
                {lists:reverse([CurrRate | lists:reverse(Rates)]), Acc, Acc / ?SAMPCOUNT_5M}
        end,

    #rate{
        max = MaxRate,
        current = CurrRate,
        last5m = Last5Min,
        last_v = CurrVal,
        last5m_acc = Acc5Min,
        last5m_smpl = Last5MinSamples,
        tick = Tick + 1
    }.

do_get_slide(Name, Id, Metric, S = #slide{n_samples = NSamples}) ->
    #{
        n_samples => NSamples,
        current => do_get_slide(Name, 2, Id, Metric, S),
        last5m => do_get_slide(Name, ?SECS_5M, Id, Metric, S)
    }.

do_get_slide(Name, Window, Id, Metric, #slide{datapoints = DP0}) ->
    Datapoint = get_slide_datapoint(Name, Id, Metric),
    {N, Sum} = get_slide_window(os:system_time(second) - Window, [Datapoint | DP0], 0, 0),
    case N > 0 of
        true -> Sum div N;
        false -> 0
    end.

get_slide_window(_StartTime, [], N, S) ->
    {N, S};
get_slide_window(StartTime, [#slide_datapoint{time = T} | _], N, S) when T < StartTime ->
    {N, S};
get_slide_window(StartTime, [#slide_datapoint{samples = N, sum = S} | Rest], AccN, AccS) ->
    get_slide_window(StartTime, Rest, AccN + N, AccS + S).

get_slide_datapoint(Name, Id, Metric) ->
    CRef = get_ref(Name, Id),
    Index = idx_metric(Name, Id, slide, Metric),
    Total = counters:get(CRef, Index),
    N = counters:get(CRef, Index + 1),
    #slide_datapoint{
        sum = Total,
        samples = N,
        time = os:system_time(second)
    }.

update_slide(Name, Id, Metric, Slide0 = #slide{n_samples = NSamples, datapoints = DPs}) ->
    Datapoint = get_slide_datapoint(Name, Id, Metric),
    %% Reset counters:
    CRef = get_ref(Name, Id),
    Index = idx_metric(Name, Id, slide, Metric),
    counters:put(CRef, Index, 0),
    counters:put(CRef, Index + 1, 0),
    Slide0#slide{
        datapoints = [Datapoint | lists:droplast(DPs)],
        n_samples = Datapoint#slide_datapoint.samples + NSamples
    }.

do_get_hist(Name, Id, Metric, #hist{buckets = Buckets}) ->
    CRef = get_ref(Name, Id),
    {Index, _} = idx_metric(Name, Id, hist, Metric),
    Sum = counters:get(CRef, Index),
    {BucketCounts, TotalCount} = get_incremental_bucket_counts(CRef, Index + 1, Buckets, 0, []),
    #{
        bucket_counts => BucketCounts,
        count => TotalCount,
        sum => Sum
    }.

get_incremental_bucket_counts(CRef, Index, [], TotalAcc0, Acc) ->
    TotalAcc = TotalAcc0 + counters:get(CRef, Index),
    BucketCounts = lists:reverse([{infinity, TotalAcc} | Acc]),
    {BucketCounts, TotalAcc};
get_incremental_bucket_counts(CRef, Index, [Bucket | Rest], Total0, Acc) ->
    Total = Total0 + counters:get(CRef, Index),
    get_incremental_bucket_counts(CRef, Index + 1, Rest, Total, [{Bucket, Total} | Acc]).

format_rates_of_id(RatesPerId) ->
    maps:map(
        fun(_Metric, Rates) ->
            format_rate(Rates)
        end,
        RatesPerId
    ).

format_rate(#rate{max = Max, current = Current, last5m = Last5Min}) ->
    make_rate(Current, Max, Last5Min).

make_rate(Current, Max, Last5Min) ->
    #{
        current => precision(Current, 2),
        max => precision(Max, 2),
        last5m => precision(Last5Min, 2)
    }.

precision(Float, N) ->
    Base = math:pow(10, N),
    round(Float * Base) / Base.

desugar(Metrics) ->
    lists:map(
        fun
            (Atom) when is_atom(Atom) ->
                {counter, Atom};
            ({hist, Name}) ->
                {hist, Name, ?DEFAULT_HIST_BUCKETS};
            ({hist, Name, Buckets}) ->
                {hist, Name, lists:sort(Buckets)};
            (Spec = {_, _}) ->
                Spec
        end,
        Metrics
    ).

filter_counters(Metrics) ->
    [K || {counter, K} <- Metrics].

normalize_initial_metrics(InitMetrics) ->
    lists:map(
        fun
            ({Id, Metrics0}) ->
                Metrics = desugar(Metrics0),
                RateMetrics = filter_counters(Metrics),
                {Id, Metrics, RateMetrics};
            ({Id, Metrics0, RateMetrics}) ->
                Metrics = desugar(Metrics0),
                {Id, Metrics, RateMetrics}
        end,
        InitMetrics
    ).

create_slides(Metrics) ->
    EmptyDatapoints = [
        #slide_datapoint{sum = 0, samples = 0, time = 0}
     || _ <- lists:seq(1, ?SECS_5M div ?SAMPLING)
    ],
    maps:from_list([{K, #slide{datapoints = EmptyDatapoints}} || {slide, K} <- Metrics]).

create_hists(Metrics) ->
    maps:from_list([
        {K, #hist{buckets = Buckets}}
     || {hist, K, Buckets} <- Metrics
    ]).

is_superset_of(RateMetrics, Metrics) ->
    case RateMetrics -- filter_counters(Metrics) of
        [] ->
            true;
        [_ | _] ->
            false
    end.

handle_create_metrics(#state{name = Name} = State0, Id, Metrics, RateMetrics) ->
    #state{metric_ids = MIDs0, rates = Rates0, slides = Slides0, hists = Hists0} = State0,
    case is_superset_of(RateMetrics, Metrics) of
        true ->
            RatesPerId = maps:from_list([{M, #rate{}} || M <- RateMetrics]),
            Rates =
                case Rates0 of
                    undefined -> #{Id => RatesPerId};
                    _ -> Rates0#{Id => RatesPerId}
                end,
            Slides = Slides0#{Id => create_slides(Metrics)},
            Hists = Hists0#{Id => create_hists(Metrics)},
            MIDs = sets:add_element(Id, MIDs0),
            State = State0#state{
                metric_ids = MIDs,
                rates = Rates,
                slides = Slides,
                hists = Hists
            },
            Result = create_counters(Name, Id, Metrics),
            {Result, State};
        false ->
            {{error, {not_super_set_of, {RateMetrics, Metrics}}}, State0}
    end.

handle_create_initial_metrics(State0, []) ->
    {ok, State0};
handle_create_initial_metrics(State0, [{Id, Metrics, RateMetrics} | Rest]) ->
    case handle_create_metrics(State0, Id, Metrics, RateMetrics) of
        {ok, State1} ->
            handle_create_initial_metrics(State1, Rest);
        {{error, _} = Error, _State} ->
            Error
    end.

handle_ensure_metrics(#state{name = Name} = State0, Id, Metrics, RateMetrics) ->
    #state{metric_ids = MIDs, rates = Rates, slides = Slides, hists = Hists} = State0,
    HasMetricId = sets:is_element(Id, MIDs),
    %% Chech if all counters are present
    CounterKeys = filter_counters(Metrics),
    CurrentCounters = get_counters(Name, Id),
    HasAllCounters = [] =:= (CounterKeys -- maps:keys(CurrentCounters)),
    %% Check if all rates are present
    CurrentRates =
        %% todo: no need to have `undefined' here?
        case Rates of
            #{Id := Rs} -> maps:keys(Rs);
            _ -> []
        end,
    HasRates = [] =:= (RateMetrics -- CurrentRates),
    %% Check if all slides are present
    SlideKeys = [K || {slide, K} <- Metrics],
    CurrentSlides = maps:keys(maps:get(Id, Slides, #{})),
    HasSlides = [] =:= (SlideKeys -- CurrentSlides),
    %% Check if all histograms are present
    HistKeys = [K || {hist, K, _} <- Metrics],
    CurrentHists = maps:keys(maps:get(Id, Hists, #{})),
    HasHists = [] =:= (HistKeys -- CurrentHists),
    case HasMetricId andalso HasAllCounters andalso HasRates andalso HasSlides andalso HasHists of
        true ->
            {{ok, already_created}, State0};
        false ->
            case handle_create_metrics(State0, Id, Metrics, RateMetrics) of
                {ok, State} -> {{ok, created}, State};
                {Result, State} -> {Result, State}
            end
    end.
