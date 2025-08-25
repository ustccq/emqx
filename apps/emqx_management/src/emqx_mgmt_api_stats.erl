%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_mgmt_api_stats).

-behaviour(minirest_api).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-import(
    hoconsc,
    [
        mk/2,
        ref/1,
        ref/2,
        array/1
    ]
).

-export([
    api_spec/0,
    paths/0,
    schema/1,
    fields/1,
    namespace/0
]).

-export([list/2]).

namespace() -> undefined.

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true}).

paths() ->
    ["/stats"].

schema("/stats") ->
    #{
        'operationId' => list,
        get =>
            #{
                description => ?DESC(emqx_stats),
                tags => [<<"Metrics">>],
                parameters => [ref(aggregate)],
                responses =>
                    #{
                        200 => mk(
                            hoconsc:union([
                                array(ref(?MODULE, per_node_data)),
                                ref(?MODULE, aggregated_data)
                            ]),
                            #{desc => ?DESC("api_rsp_200")}
                        )
                    }
            }
    }.

fields(aggregate) ->
    [
        {aggregate,
            mk(
                boolean(),
                #{
                    desc => ?DESC("aggregate"),
                    in => query,
                    required => false,
                    example => false
                }
            )}
    ];
fields(aggregated_data) ->
    [
        stats_schema('channels.count', <<"sessions.count">>),
        stats_schema('channels.max', <<"session.max">>),
        stats_schema('connections.count', <<"Number of current connections">>),
        stats_schema('connections.max', <<"Historical maximum number of connections">>),
        stats_schema('delayed.count', <<"Number of delayed messages">>),
        stats_schema('delayed.max', <<"Historical maximum number of delayed messages">>),
        stats_schema('live_connections.count', <<"Number of current live connections">>),
        stats_schema('live_connections.max', <<"Historical maximum number of live connections">>),
        stats_schema('cluster_sessions.count', <<"Number of sessions in the cluster">>),
        stats_schema(
            'cluster_sessions.max', <<"Historical maximum number of sessions in the cluster">>
        ),
        stats_schema('retained.count', <<"Number of currently retained messages">>),
        stats_schema('retained.max', <<"Historical maximum number of retained messages">>),
        stats_schema('sessions.count', <<"Number of current sessions">>),
        stats_schema('sessions.max', <<"Historical maximum number of sessions">>),
        stats_schema('suboptions.count', <<"subscriptions.count">>),
        stats_schema('suboptions.max', <<"subscriptions.max">>),
        stats_schema('subscribers.count', <<"Number of current subscribers">>),
        stats_schema('subscribers.max', <<"Historical maximum number of subscribers">>),
        stats_schema(
            'subscriptions.count',
            <<
                "Number of current subscriptions, including shared subscriptions,"
                " but not subscriptions from durable sessions"
            >>
        ),
        stats_schema('subscriptions.max', <<"Historical maximum number of subscriptions">>),
        stats_schema('subscriptions.shared.count', <<"Number of current shared subscriptions">>),
        stats_schema(
            'subscriptions.shared.max', <<"Historical maximum number of shared subscriptions">>
        ),
        stats_schema('topics.count', <<"Number of current topics">>),
        stats_schema('topics.max', <<"Historical maximum number of topics">>)
    ];
fields(per_node_data) ->
    [
        {node,
            mk(string(), #{
                desc => ?DESC("node_name"),
                example => <<"emqx@127.0.0.1">>
            })},
        stats_schema(
            'durable_subscriptions.count',
            <<"Number of current subscriptions from durable sessions in the cluster">>
        )
    ] ++ fields(aggregated_data).

stats_schema(Name, Desc) ->
    {Name, mk(non_neg_integer(), #{desc => Desc, example => 0})}.

%%%==============================================================================================
%% api apply
list(get, #{query_string := Qs}) ->
    case maps:get(<<"aggregate">>, Qs, undefined) of
        true ->
            {200, emqx_mgmt:get_stats()};
        _ ->
            Data = lists:foldl(
                fun(Node, Acc) ->
                    case emqx_mgmt:get_stats(Node) of
                        {error, _Err} ->
                            Acc;
                        Stats when is_list(Stats) ->
                            Data = maps:from_list([{node, Node} | Stats]),
                            [Data | Acc]
                    end
                end,
                [],
                emqx:running_nodes()
            ),
            {200, Data}
    end.

%%%==============================================================================================
%% Internal
