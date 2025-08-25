%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_retainer_index_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

t_foreach_index_key(_Config) ->
    put(index_key, undefined),
    ok = emqx_retainer_index:foreach_index_key(
        fun(IndexKey) -> put(index_key, IndexKey) end,
        [[1, 3]],
        [<<"a">>, <<"b">>, <<"c">>]
    ),

    ?assertEqual(
        {[1, 3], {[<<"a">>, <<"c">>], [<<"b">>]}},
        get(index_key)
    ).

t_to_index_key(_Config) ->
    ?assertEqual(
        {[1, 3], {[<<"a">>, <<"c">>], [<<"b">>]}},
        emqx_retainer_index:to_index_key(
            [1, 3],
            [<<"a">>, <<"b">>, <<"c">>]
        )
    ),

    ?assertEqual(
        {[1, 4], {[<<"a">>], [<<"b">>, <<"c">>]}},
        emqx_retainer_index:to_index_key(
            [1, 4],
            [<<"a">>, <<"b">>, <<"c">>]
        )
    ),

    ?assertEqual(
        {[1, 2, 3], {[<<"a">>], []}},
        emqx_retainer_index:to_index_key(
            [1, 2, 3],
            [<<"a">>]
        )
    ),

    ?assertEqual(
        {[3, 5], {[<<"b">>], [<<"x">>, <<"a">>, <<"y">>]}},
        emqx_retainer_index:to_index_key(
            [3, 5],
            [<<"x">>, <<"a">>, <<"b">>, <<"y">>]
        )
    ),

    ?assertEqual(
        {[3, 5], {[<<"b">>, <<"z">>], [<<"x">>, <<"a">>, <<"y">>]}},
        emqx_retainer_index:to_index_key(
            [3, 5],
            [<<"x">>, <<"a">>, <<"b">>, <<"y">>, <<"z">>]
        )
    ).

t_index_score(_Config) ->
    ?assertEqual(
        0,
        emqx_retainer_index:index_score(
            [1, 4],
            ['+', <<"a">>, <<"b">>, '+']
        )
    ),

    ?assertEqual(
        0,
        emqx_retainer_index:index_score(
            [1, 2],
            ['+', <<"a">>, <<"b">>, '+']
        )
    ),

    ?assertEqual(
        2,
        emqx_retainer_index:index_score(
            [1, 2],
            [<<"a">>, <<"b">>, '+']
        )
    ),

    ?assertEqual(
        1,
        emqx_retainer_index:index_score(
            [1, 2],
            [<<"a">>]
        )
    ),

    ?assertEqual(
        1,
        emqx_retainer_index:index_score(
            [2, 3, 4, 5],
            ['+', <<"a">>, '#']
        )
    ),

    ?assertEqual(
        2,
        emqx_retainer_index:index_score(
            [2, 3, 4, 5],
            ['+', <<"a">>, <<"b">>, '+']
        )
    ).

t_select_index(_Config) ->
    ?assertEqual(
        [2, 3, 4, 5],
        emqx_retainer_index:select_index(
            ['+', <<"a">>, <<"b">>, '+'],
            [
                [1, 4],
                [2, 3, 4, 5],
                [1, 2]
            ]
        )
    ),

    ?assertEqual(
        undefined,
        emqx_retainer_index:select_index(
            ['+', <<"a">>, <<"b">>, '+'],
            [
                [1, 4]
            ]
        )
    ).

t_condition(_Config) ->
    ?assertEqual(
        ['_', <<"a">>, <<"b">>, '_'],
        emqx_retainer_index:condition(
            ['+', <<"a">>, <<"b">>, '+']
        )
    ),

    ?assertEqual(
        ['_', <<"a">> | '_'],
        emqx_retainer_index:condition(
            ['+', <<"a">>, '#']
        )
    ).

t_condition_index(_Config) ->
    ?assertEqual(
        {{[2, 3], {[<<"a">>, <<"b">>], ['_', '_']}}, true},
        emqx_retainer_index:condition(
            [2, 3],
            ['+', <<"a">>, <<"b">>, '+']
        )
    ),

    ?assertEqual(
        {{[3, 4], {[<<"b">>, '_'], ['_', <<"a">>]}}, true},
        emqx_retainer_index:condition(
            [3, 4],
            ['+', <<"a">>, <<"b">>, '+']
        )
    ),

    ?assertEqual(
        {{[3, 5], {[<<"b">>], ['_', <<"a">>, '_']}}, true},
        emqx_retainer_index:condition(
            [3, 5],
            ['+', <<"a">>, <<"b">>, '+']
        )
    ),

    ?assertEqual(
        {{[3, 5], {[<<"b">> | '_'], ['_', <<"a">> | '_']}}, false},
        emqx_retainer_index:condition(
            [3, 5],
            ['+', <<"a">>, <<"b">>, '#']
        )
    ),

    ?assertEqual(
        {{[3, 4], {[<<"b">> | '_'], ['_', <<"a">> | '_']}}, false},
        emqx_retainer_index:condition(
            [3, 4],
            ['+', <<"a">>, <<"b">>, '#']
        )
    ),

    ?assertEqual(
        {{[1], {[<<"a">>], '_'}}, true},
        emqx_retainer_index:condition(
            [1],
            [<<"a">>, '#']
        )
    ),

    ?assertEqual(
        {{[1, 2, 3], {['', <<"saya">>, '_'], []}}, true},
        emqx_retainer_index:condition(
            [1, 2, 3],
            ['', <<"saya">>, '+']
        )
    ),

    ?assertEqual(
        {{[1, 2, 3], {[<<"c">>], []}}, true},
        emqx_retainer_index:condition(
            [1, 2, 3],
            [<<"c">>]
        )
    ),

    ?assertEqual(
        {{[1, 2, 3], {[<<"c">> | '_'], '_'}}, false},
        emqx_retainer_index:condition(
            [1, 2, 3],
            [<<"c">>, '#']
        )
    ),

    ?assertEqual(
        {{[1], {['_'], '_'}}, true},
        emqx_retainer_index:condition(
            [1],
            ['+', '#']
        )
    ).

% {[2],[[<<48>>,<<48>>]],['+','+','#']}

t_restore_topic(_Config) ->
    ?assertEqual(
        [<<"x">>, <<"a">>, <<"b">>, <<"y">>],
        emqx_retainer_index:restore_topic(
            {[2, 3], {[<<"a">>, <<"b">>], [<<"x">>, <<"y">>]}}
        )
    ),

    ?assertEqual(
        [<<"x">>, <<"a">>, <<"b">>, <<"y">>],
        emqx_retainer_index:restore_topic(
            {[3, 4], {[<<"b">>, <<"y">>], [<<"x">>, <<"a">>]}}
        )
    ),

    ?assertEqual(
        [<<"x">>, <<"a">>, <<"b">>, <<"y">>],
        emqx_retainer_index:restore_topic(
            {[3, 5], {[<<"b">>], [<<"x">>, <<"a">>, <<"y">>]}}
        )
    ),

    ?assertEqual(
        [<<"a">>],
        emqx_retainer_index:restore_topic(
            {[1, 2, 3], {[<<"a">>], []}}
        )
    ).
