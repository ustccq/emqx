%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_topic_metrics_api_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-import(emqx_mgmt_api_test_util, [request/2, request/3, uri/1]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

suite() -> [{timetrap, {seconds, 30}}].

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_testcase(_, Config) ->
    lists:foreach(
        fun emqx_modules_conf:remove_topic_metrics/1,
        emqx_modules_conf:topic_metrics()
    ),
    Config.

init_per_suite(Config) ->
    %% For some unknown reason, this test suite depends on
    %% `gen_rpc` not starting with its default settings before `emqx_conf`.
    %% `gen_rpc` and `emqx_conf` have different default `port_discovery` modes,
    %% so we reinitialize `gen_rpc` explicitly.
    Apps = emqx_cth_suite:start(
        [
            {gen_rpc, #{override_env => [{port_discovery, stateless}]}},
            {emqx_conf, "rpc.port_discovery = stateless"},
            emqx_modules,
            emqx_management,
            emqx_mgmt_api_test_util:emqx_dashboard()
        ],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    Apps = ?config(apps, Config),
    emqx_cth_suite:stop(Apps),
    ok.

%%------------------------------------------------------------------------------
%% Tests
%%------------------------------------------------------------------------------

t_mqtt_topic_metrics_collection(_) ->
    {ok, 200, Result0} = request(
        get,
        uri(["mqtt", "topic_metrics"])
    ),

    ?assertEqual(
        [],
        emqx_utils_json:decode(Result0)
    ),

    {ok, 200, _} = request(
        post,
        uri(["mqtt", "topic_metrics"]),
        #{<<"topic">> => <<"topic/1/2">>}
    ),

    {ok, 200, Result1} = request(
        get,
        uri(["mqtt", "topic_metrics"])
    ),

    ?assertMatch(
        [
            #{
                <<"topic">> := <<"topic/1/2">>,
                <<"metrics">> := #{}
            }
        ],
        emqx_utils_json:decode(Result1)
    ),

    ?assertMatch(
        {ok, 200, _},
        request(
            put,
            uri(["mqtt", "topic_metrics"]),
            #{
                <<"topic">> => <<"topic/1/2">>,
                <<"action">> => <<"reset">>
            }
        )
    ),

    ?assertMatch(
        {ok, 200, _},
        request(
            put,
            uri(["mqtt", "topic_metrics"]),
            #{<<"action">> => <<"reset">>}
        )
    ),

    ?assertMatch(
        {ok, 404, _},
        request(
            put,
            uri(["mqtt", "topic_metrics"]),
            #{
                <<"topic">> => <<"unknown_topic/1/2">>,
                <<"action">> => <<"reset">>
            }
        )
    ),
    ?assertMatch(
        {ok, 204, _},
        request(
            delete,
            uri(["mqtt", "topic_metrics", emqx_http_lib:uri_encode("topic/1/2")])
        )
    ).

t_mqtt_topic_metrics(_) ->
    {ok, 200, _} = request(
        post,
        uri(["mqtt", "topic_metrics"]),
        #{<<"topic">> => <<"topic/1/2">>}
    ),

    {ok, 200, Result0} = request(
        get,
        uri(["mqtt", "topic_metrics"])
    ),

    ?assertMatch([_], emqx_utils_json:decode(Result0)),

    {ok, 200, Result1} = request(
        get,
        uri(["mqtt", "topic_metrics", emqx_http_lib:uri_encode("topic/1/2")])
    ),

    ?assertMatch(
        #{
            <<"topic">> := <<"topic/1/2">>,
            <<"metrics">> := #{}
        },
        emqx_utils_json:decode(Result1)
    ),

    ?assertMatch(
        {ok, 204, _},
        request(
            delete,
            uri(["mqtt", "topic_metrics", emqx_http_lib:uri_encode("topic/1/2")])
        )
    ),

    ?assertMatch(
        {ok, 404, _},
        request(
            get,
            uri(["mqtt", "topic_metrics", emqx_http_lib:uri_encode("topic/1/2")])
        )
    ),

    ?assertMatch(
        {ok, 404, _},
        request(
            delete,
            uri(["mqtt", "topic_metrics", emqx_http_lib:uri_encode("topic/1/2")])
        )
    ).

t_bad_reqs(_) ->
    %% empty topic
    ?assertMatch(
        {ok, 400, _},
        request(
            post,
            uri(["mqtt", "topic_metrics"]),
            #{<<"topic">> => <<"">>}
        )
    ),

    %% wildcard
    ?assertMatch(
        {ok, 400, _},
        request(
            post,
            uri(["mqtt", "topic_metrics"]),
            #{<<"topic">> => <<"foo/+/bar">>}
        )
    ),

    {ok, 200, _} = request(
        post,
        uri(["mqtt", "topic_metrics"]),
        #{<<"topic">> => <<"topic/1/2">>}
    ),

    %% existing topic
    ?assertMatch(
        {ok, 400, _},
        request(
            post,
            uri(["mqtt", "topic_metrics"]),
            #{<<"topic">> => <<"topic/1/2">>}
        )
    ),

    ok = emqx_modules_conf:remove_topic_metrics(<<"topic/1/2">>),

    %% limit
    Responses = lists:map(
        fun(N) ->
            Topic = iolist_to_binary([
                <<"topic/">>,
                integer_to_binary(N)
            ]),
            request(
                post,
                uri(["mqtt", "topic_metrics"]),
                #{<<"topic">> => Topic}
            )
        end,
        lists:seq(1, 513)
    ),

    ?assertMatch(
        [{ok, 409, _}, {ok, 200, _} | _],
        lists:reverse(Responses)
    ),

    %% limit && wildcard
    ?assertMatch(
        {ok, 400, _},
        request(
            post,
            uri(["mqtt", "topic_metrics"]),
            #{<<"topic">> => <<"a/+">>}
        )
    ).

t_node_aggregation(_) ->
    TwoNodeResult = [
        #{
            create_time => <<"2022-03-30T13:54:10+03:00">>,
            metrics => #{'messages.dropped.count' => 1},
            reset_time => <<"2022-03-30T13:54:10+03:00">>,
            topic => <<"topic/1/2">>
        },
        #{
            create_time => <<"2022-03-30T13:54:10+03:00">>,
            metrics => #{'messages.dropped.count' => 2},
            reset_time => <<"2022-03-30T13:54:10+03:00">>,
            topic => <<"topic/1/2">>
        }
    ],

    meck:new(emqx_topic_metrics_proto_v1, [passthrough]),
    meck:expect(emqx_topic_metrics_proto_v1, metrics, 2, {TwoNodeResult, []}),

    {ok, 200, Result} = request(
        get,
        uri(["mqtt", "topic_metrics", emqx_http_lib:uri_encode("topic/1/2")])
    ),

    ?assertMatch(
        #{
            <<"topic">> := <<"topic/1/2">>,
            <<"metrics">> := #{<<"messages.dropped.count">> := 3}
        },
        emqx_utils_json:decode(Result)
    ),

    meck:unload(emqx_topic_metrics_proto_v1).
t_badrpc(_) ->
    meck:new(emqx_topic_metrics_proto_v1, [passthrough]),
    meck:expect(emqx_topic_metrics_proto_v1, metrics, 2, {[], [node()]}),

    ?assertMatch(
        {ok, 500, _},
        request(
            get,
            uri(["mqtt", "topic_metrics", emqx_http_lib:uri_encode("topic/1/2")])
        )
    ),

    meck:unload(emqx_topic_metrics_proto_v1).

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------
