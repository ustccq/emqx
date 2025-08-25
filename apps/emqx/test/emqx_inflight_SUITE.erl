%%--------------------------------------------------------------------
%% Copyright (c) 2017-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_inflight_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() -> emqx_common_test_helpers:all(?MODULE).

t_contain(_) ->
    Inflight = emqx_inflight:insert(k, v, emqx_inflight:new()),
    ?assert(emqx_inflight:contain(k, Inflight)),
    ?assertNot(emqx_inflight:contain(badkey, Inflight)).

t_lookup(_) ->
    Inflight = emqx_inflight:insert(k, v, emqx_inflight:new()),
    ?assertEqual({value, v}, emqx_inflight:lookup(k, Inflight)),
    ?assertEqual(none, emqx_inflight:lookup(badkey, Inflight)).

t_insert(_) ->
    Inflight = emqx_inflight:insert(
        b,
        2,
        emqx_inflight:insert(
            a, 1, emqx_inflight:new()
        )
    ),
    ?assertEqual(2, emqx_inflight:size(Inflight)),
    ?assertEqual({value, 1}, emqx_inflight:lookup(a, Inflight)),
    ?assertEqual({value, 2}, emqx_inflight:lookup(b, Inflight)),
    ?assertError({key_exists, a}, emqx_inflight:insert(a, 1, Inflight)).

t_update(_) ->
    Inflight = emqx_inflight:insert(k, v, emqx_inflight:new()),
    ?assertEqual(Inflight, emqx_inflight:update(k, v, Inflight)),
    ?assertError(function_clause, emqx_inflight:update(badkey, v, Inflight)).

t_resize(_) ->
    Inflight = emqx_inflight:insert(k, v, emqx_inflight:new(2)),
    ?assertEqual(1, emqx_inflight:size(Inflight)),
    ?assertEqual(2, emqx_inflight:max_size(Inflight)),
    Inflight1 = emqx_inflight:resize(4, Inflight),
    ?assertEqual(4, emqx_inflight:max_size(Inflight1)),
    ?assertEqual(1, emqx_inflight:size(Inflight)).

t_delete(_) ->
    Inflight = emqx_inflight:insert(k, v, emqx_inflight:new(2)),
    Inflight1 = emqx_inflight:delete(k, Inflight),
    ?assert(emqx_inflight:is_empty(Inflight1)),
    ?assertNot(emqx_inflight:contain(k, Inflight1)).

t_values(_) ->
    Inflight = emqx_inflight:insert(
        b,
        2,
        emqx_inflight:insert(
            a, 1, emqx_inflight:new()
        )
    ),
    ?assertEqual([1, 2], emqx_inflight:values(Inflight)),
    ?assertEqual([{a, 1}, {b, 2}], emqx_inflight:to_list(Inflight)).

t_fold(_) ->
    Inflight = maps:fold(
        fun emqx_inflight:insert/3,
        emqx_inflight:new(),
        #{a => 1, b => 2, c => 42}
    ),
    ?assertEqual(
        emqx_inflight:fold(fun(_, V, S) -> S + V end, 0, Inflight),
        lists:foldl(fun({_, V}, S) -> S + V end, 0, emqx_inflight:to_list(Inflight))
    ).

t_is_full(_) ->
    Inflight = emqx_inflight:insert(k, v, emqx_inflight:new()),
    ?assertNot(emqx_inflight:is_full(Inflight)),
    Inflight1 = emqx_inflight:insert(
        b,
        2,
        emqx_inflight:insert(
            a, 1, emqx_inflight:new(2)
        )
    ),
    ?assert(emqx_inflight:is_full(Inflight1)).

t_is_empty(_) ->
    Inflight = emqx_inflight:insert(a, 1, emqx_inflight:new(2)),
    ?assertNot(emqx_inflight:is_empty(Inflight)),
    Inflight1 = emqx_inflight:delete(a, Inflight),
    ?assert(emqx_inflight:is_empty(Inflight1)).

t_window(_) ->
    ?assertEqual([], emqx_inflight:window(emqx_inflight:new(0))),
    Inflight = emqx_inflight:insert(
        b,
        2,
        emqx_inflight:insert(
            a, 1, emqx_inflight:new(2)
        )
    ),
    ?assertEqual([a, b], emqx_inflight:window(Inflight)).

t_to_list(_) ->
    Inflight = lists:foldl(
        fun(Seq, InflightAcc) ->
            emqx_inflight:insert(Seq, integer_to_binary(Seq), InflightAcc)
        end,
        emqx_inflight:new(100),
        [1, 6, 2, 3, 10, 7, 9, 8, 4, 5]
    ),
    ExpList = [{Seq, integer_to_binary(Seq)} || Seq <- lists:seq(1, 10)],
    ?assertEqual(ExpList, emqx_inflight:to_list(Inflight)).
