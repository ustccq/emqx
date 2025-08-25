%%--------------------------------------------------------------------
%% Copyright (c) 2017-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% This module manages an opaque collection of statistics data used to
%% force garbage collection on `self()' process when hitting thresholds.
%% Namely:
%% (1) Total number of messages passed through
%% (2) Total data volume passed through
%% @end
%%--------------------------------------------------------------------

-module(emqx_gc).

-include("types.hrl").

-export([
    init/1,
    run/3,
    info/1,
    reset/1
]).

-export_type([opts/0, gc_state/0]).

-type opts() :: #{
    count => integer(),
    bytes => integer()
}.

-type st() :: #{
    cnt => {integer(), integer()},
    oct => {integer(), integer()}
}.

-opaque gc_state() :: {gc_state, st()}.

-define(GCS(St), {gc_state, St}).

-define(disabled, disabled).
-define(ENABLED(X), (is_integer(X) andalso X > 0)).

%% @doc Initialize force GC state.
-spec init(opts()) -> gc_state().
init(#{count := Count, bytes := Bytes}) ->
    Cnt = [{cnt, {Count, Count}} || ?ENABLED(Count)],
    Oct = [{oct, {Bytes, Bytes}} || ?ENABLED(Bytes)],
    ?GCS(maps:from_list(Cnt ++ Oct)).

%% @doc Try to run GC based on reductions of count or bytes.
-spec run(pos_integer(), pos_integer(), gc_state()) ->
    {boolean(), gc_state()}.
run(Cnt, Oct, ?GCS(St)) ->
    {Res, St1} = do_run([{cnt, Cnt}, {oct, Oct}], St),
    {Res, ?GCS(St1)}.

do_run([], St) ->
    {false, St};
do_run([{K, N} | T], St) ->
    case dec(K, N, St) of
        {true, St1} ->
            erlang:garbage_collect(),
            {true, do_reset(St1)};
        {false, St1} ->
            do_run(T, St1)
    end.

%% @doc Info of GC state.
-spec info(option(gc_state())) -> option(map()).
info(?GCS(St)) -> St.

%% @doc Reset counters to zero.
-spec reset(option(gc_state())) -> gc_state().
reset(?GCS(St)) ->
    ?GCS(do_reset(St)).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

-spec dec(cnt | oct, pos_integer(), st()) -> {boolean(), st()}.
dec(Key, Num, St) ->
    case maps:get(Key, St, ?disabled) of
        ?disabled ->
            {false, St};
        {Init, Remain} when Remain > Num ->
            {false, maps:put(Key, {Init, Remain - Num}, St)};
        _ ->
            {true, St}
    end.

do_reset(St) ->
    do_reset(cnt, do_reset(oct, St)).

%% Reset counters to zero.
do_reset(Key, St) ->
    case maps:get(Key, St, ?disabled) of
        ?disabled -> St;
        {Init, _} -> maps:put(Key, {Init, Init}, St)
    end.
