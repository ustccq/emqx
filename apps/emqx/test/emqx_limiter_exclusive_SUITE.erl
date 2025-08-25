%%--------------------------------------------------------------------
%% Copyright (c) 2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_limiter_exclusive_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

%%--------------------------------------------------------------------
%% Setups
%%--------------------------------------------------------------------

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    Apps = emqx_cth_suite:start([emqx], #{work_dir => emqx_cth_suite:work_dir(Config)}),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    emqx_cth_suite:stop(?config(apps, Config)).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Groups = emqx_limiter_registry:list_groups(),
    lists:foreach(
        fun(Group) ->
            emqx_limiter:delete_group(Group)
        end,
        Groups
    ),
    Config.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

t_try_consume(_) ->
    ok = emqx_limiter:create_group(exclusive, group1, [
        {limiter1, #{capacity => 2, interval => 100, burst_capacity => 0}}
    ]),

    %% Create two different clients to consume tokens
    ClientA0 = emqx_limiter:connect({group1, limiter1}),
    ClientB0 = emqx_limiter:connect({group1, limiter1}),

    %% Consume both tokens concurrently, each client has its own bucket
    {true, ClientA1} = emqx_limiter_client:try_consume(ClientA0, 1),
    {true, ClientB1} = emqx_limiter_client:try_consume(ClientB0, 1),
    {true, ClientA2} = emqx_limiter_client:try_consume(ClientA1, 1),
    {true, ClientB2} = emqx_limiter_client:try_consume(ClientB1, 1),
    {false, ClientA3, {failed_to_consume_from_limiter, {group1, limiter1}}} = emqx_limiter_client:try_consume(
        ClientA2, 1
    ),
    {false, ClientB3, {failed_to_consume_from_limiter, {group1, limiter1}}} = emqx_limiter_client:try_consume(
        ClientB2, 1
    ),
    ct:sleep(110),

    %% Capacity should be refilled to each client independently
    {true, ClientA4} = emqx_limiter_client:try_consume(ClientA3, 1),
    {true, ClientB4} = emqx_limiter_client:try_consume(ClientB3, 1),
    {true, ClientA5} = emqx_limiter_client:try_consume(ClientA4, 1),
    {true, ClientB5} = emqx_limiter_client:try_consume(ClientB4, 1),
    {false, _ClientA6, _} = emqx_limiter_client:try_consume(ClientA5, 1),
    {false, _ClientB6, _} = emqx_limiter_client:try_consume(ClientB5, 1).

t_try_consume_burst(_) ->
    ok = emqx_limiter:create_group(exclusive, group1, [
        {limiter1, #{capacity => 2, interval => 100, burst_capacity => 8, burst_interval => 1000}}
    ]),
    Client0 = emqx_limiter:connect({group1, limiter1}),

    %% Consume full capacity
    Client1 = lists:foldl(
        fun(_, ClientAcc0) ->
            {true, ClientAcc1} = emqx_limiter_client:try_consume(ClientAcc0, 1),
            ClientAcc1
        end,
        Client0,
        lists:seq(1, 10)
    ),
    {false, Client2, _} = emqx_limiter_client:try_consume(Client1, 1),

    ct:sleep(110),
    %% Only regularly refilled tokens are available
    {true, Client3} = emqx_limiter_client:try_consume(Client2, 1),
    {true, Client4} = emqx_limiter_client:try_consume(Client3, 1),
    {false, Client5, _} = emqx_limiter_client:try_consume(Client4, 1),

    ct:sleep(900),
    %% Burst tokens are available again
    lists:foldl(
        fun(_, ClientAcc0) ->
            {true, ClientAcc1} = emqx_limiter_client:try_consume(ClientAcc0, 1),
            ClientAcc1
        end,
        Client5,
        lists:seq(1, 10)
    ).

t_try_consume_burst_wide_interval(_) ->
    ok = emqx_limiter:create_group(exclusive, group1, [
        {limiter1, #{
            capacity => 10,
            interval => 200,
            burst_capacity => 1000,
            burst_interval => 3600_000
        }}
    ]),
    Client0 = emqx_limiter:connect({group1, limiter1}),

    %% Consume regular + burst capacity
    Client1 = lists:foldl(
        fun(_, ClientAcc0) ->
            {true, ClientAcc1} = emqx_limiter_client:try_consume(ClientAcc0, 1),
            ClientAcc1
        end,
        Client0,
        lists:seq(1, 10 + 1000)
    ),
    {false, Client2, _} = emqx_limiter_client:try_consume(Client1, 1),

    %% Wait for considerably more than one regular refill interval
    ct:sleep(1000),

    %% Only regularly refilled tokens are available
    Client3 = lists:foldl(
        fun(_, ClientAcc0) ->
            {true, ClientAcc1} = emqx_limiter_client:try_consume(ClientAcc0, 1),
            ClientAcc1
        end,
        Client2,
        lists:seq(1, 10)
    ),
    {false, _Client, _} = emqx_limiter_client:try_consume(Client3, 1).

t_put_back(_) ->
    ok = emqx_limiter:create_group(exclusive, group1, [
        {limiter1, #{capacity => 2, interval => 100, burst_capacity => 0}}
    ]),

    %% Create a client and consume tokens
    Client0 = emqx_limiter:connect({group1, limiter1}),
    {true, Client1} = emqx_limiter_client:try_consume(Client0, 1),
    {true, Client2} = emqx_limiter_client:try_consume(Client1, 1),
    {false, Client3, _} = emqx_limiter_client:try_consume(Client2, 1),

    %% Put back one token
    Client4 = emqx_limiter_client:put_back(Client3, 1),

    %% Check if the token is refilled back
    {true, Client5} = emqx_limiter_client:try_consume(Client4, 1),
    {false, _Client6, _} = emqx_limiter_client:try_consume(Client5, 1).

t_change_options(_) ->
    ok = emqx_limiter:create_group(exclusive, group1, [
        {limiter1, #{capacity => 1, interval => 100, burst_capacity => 0}}
    ]),

    %% Create a client and consume tokens
    Client0 = emqx_limiter:connect({group1, limiter1}),
    {true, Client1} = emqx_limiter_client:try_consume(Client0, 1),
    {false, Client2, _} = emqx_limiter_client:try_consume(Client1, 1),

    %% Change the options, increase the capacity and interval
    ok = emqx_limiter:update_group(group1, [
        {limiter1, #{capacity => 2, interval => 200, burst_capacity => 0}}
    ]),

    %% The tokens will be refilled at the end of the NEW interval
    ct:sleep(210),
    {true, Client3} = emqx_limiter_client:try_consume(Client2, 1),
    {true, Client4} = emqx_limiter_client:try_consume(Client3, 1),
    {false, _Client5, _} = emqx_limiter_client:try_consume(Client4, 1).
