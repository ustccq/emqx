%%--------------------------------------------------------------------
%% Copyright (c) 2018-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_batch_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() -> emqx_common_test_helpers:all(?MODULE).

t_batch_full_commit(_) ->
    B0 = emqx_batch:init(#{
        batch_size => 3,
        linger_ms => 2000,
        commit_fun => fun(_) -> ok end
    }),
    B3 = lists:foldl(fun(E, B) -> emqx_batch:push(E, B) end, B0, [a, b, c]),
    ?assertEqual(3, emqx_batch:size(B3)),
    ?assertEqual([a, b, c], emqx_batch:items(B3)),
    %% Trigger commit fun.
    B4 = emqx_batch:push(a, B3),
    ?assertEqual(0, emqx_batch:size(B4)),
    ?assertEqual([], emqx_batch:items(B4)).

t_batch_linger_commit(_) ->
    CommitFun = fun(Q) -> ?assertEqual(3, length(Q)) end,
    B0 = emqx_batch:init(#{
        batch_size => 3,
        linger_ms => 500,
        commit_fun => CommitFun
    }),
    B3 = lists:foldl(fun(E, B) -> emqx_batch:push(E, B) end, B0, [a, b, c]),
    ?assertEqual(3, emqx_batch:size(B3)),
    ?assertEqual([a, b, c], emqx_batch:items(B3)),
    receive
        batch_linger_expired ->
            B4 = emqx_batch:commit(B3),
            ?assertEqual(0, emqx_batch:size(B4)),
            ?assertEqual([], emqx_batch:items(B4))
    after 1000 ->
        error(linger_timer_not_triggered)
    end.
