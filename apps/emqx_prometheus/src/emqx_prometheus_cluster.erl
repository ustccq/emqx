%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_prometheus_cluster).

-include_lib("emqx/include/logger.hrl").
-include("emqx_prometheus.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").

-export([
    raw_data/2,

    collect_json_data/2,

    point_to_map_fun/1,

    boolean_to_number/1,
    status_to_number/1,
    metric_names/1
]).

-callback fetch_cluster_consistented_data() -> map().

-callback fetch_from_local_node(atom()) -> {node(), map()}.

-callback aggre_or_zip_init_acc() -> map().

-callback logic_sum_metrics() -> list().

-define(MG(K, MAP), maps:get(K, MAP)).

raw_data(Module, undefined) ->
    %% TODO: for push gateway, the format mode should be configurable
    raw_data(Module, ?PROM_DATA_MODE__NODE);
raw_data(Module, ?PROM_DATA_MODE__ALL_NODES_AGGREGATED = Mode) ->
    AllNodesMetrics = aggre_cluster(Module, Mode),
    %% TODO: fix this typo
    Cluster = Module:fetch_cluster_consistented_data(),
    maps:merge(AllNodesMetrics, Cluster);
raw_data(Module, ?PROM_DATA_MODE__ALL_NODES_UNAGGREGATED = Mode) ->
    AllNodesMetrics = zip_cluster_data(Module, Mode),
    %% TODO: fix this typo
    Cluster = Module:fetch_cluster_consistented_data(),
    maps:merge(AllNodesMetrics, Cluster);
raw_data(Module, ?PROM_DATA_MODE__NODE = Mode) ->
    {_Node, LocalNodeMetrics} = Module:fetch_from_local_node(Mode),
    %% TODO: fix this typo
    Cluster = Module:fetch_cluster_consistented_data(),
    maps:merge(LocalNodeMetrics, Cluster).

fetch_data_from_all_nodes(Module, Mode) ->
    Nodes = mria:running_nodes(),
    _ResL = emqx_prometheus_proto_v2:raw_prom_data(
        Nodes, Module, fetch_from_local_node, [Mode]
    ).

collect_json_data(Data, Func) when is_function(Func, 3) ->
    maps:fold(
        fun(K, V, Acc) ->
            Func(K, V, Acc)
        end,
        [],
        Data
    );
collect_json_data(_, _) ->
    error(badarg).

aggre_cluster(Module, Mode) ->
    do_aggre_cluster(
        Module:logic_sum_metrics(),
        fetch_data_from_all_nodes(Module, Mode),
        Module:aggre_or_zip_init_acc()
    ).

do_aggre_cluster(_LogicSumKs, [], AccIn) ->
    AccIn;
do_aggre_cluster(LogicSumKs, [{ok, {_NodeName, NodeMetric}} | Rest], AccIn) ->
    do_aggre_cluster(
        LogicSumKs,
        Rest,
        maps:fold(
            fun(K, V, AccIn0) ->
                AccIn0#{K => aggre_metric(LogicSumKs, V, ?MG(K, AccIn0))}
            end,
            AccIn,
            NodeMetric
        )
    );
do_aggre_cluster(LogicSumKs, [{_, _} | Rest], AccIn) ->
    do_aggre_cluster(LogicSumKs, Rest, AccIn).

aggre_metric(LogicSumKs, NodeMetrics, AccIn0) ->
    lists:foldl(
        fun(K, AccIn) ->
            NAccL = do_aggre_metric(
                K, LogicSumKs, ?MG(K, NodeMetrics), ?MG(K, AccIn)
            ),
            AccIn#{K => NAccL}
        end,
        AccIn0,
        maps:keys(NodeMetrics)
    ).

do_aggre_metric(K, LogicSumKs, NodeMetrics, AccL) ->
    lists:foldl(
        fun(Point = {_Labels, _Metric}, AccIn) ->
            sum(K, LogicSumKs, Point, AccIn)
        end,
        AccL,
        NodeMetrics
    ).

sum(K, LogicSumKs, {Labels, Metric} = Point, MetricAccL) ->
    case lists:keytake(Labels, 1, MetricAccL) of
        {value, {Labels, MetricAcc}, NMetricAccL} ->
            NPoint = {Labels, do_sum(K, LogicSumKs, Metric, MetricAcc)},
            [NPoint | NMetricAccL];
        false ->
            [Point | MetricAccL]
    end.

do_sum(K, LogicSumKs, Metric, MetricAcc) ->
    case lists:member(K, LogicSumKs) of
        true ->
            logic_sum(Metric, MetricAcc);
        false ->
            deep_sum(Metric, MetricAcc)
    end.

deep_sum(Metric, MetricAcc) when is_number(Metric) andalso is_number(MetricAcc) ->
    Metric + MetricAcc;
deep_sum(Metric, MetricAcc) when is_map(Metric) andalso is_map(MetricAcc) ->
    maps:merge_with(
        fun(_K, V1, V2) ->
            deep_sum(V1, V2)
        end,
        Metric,
        MetricAcc
    );
deep_sum(Metric, MetricAcc) when
    is_list(Metric) andalso is_list(MetricAcc) andalso length(Metric) == length(MetricAcc)
->
    lists:zipwith(
        fun(V1, V2) ->
            deep_sum(V1, V2)
        end,
        Metric,
        MetricAcc
    );
deep_sum(Metric, MetricAcc) when
    is_tuple(Metric) andalso is_tuple(MetricAcc) andalso tuple_size(Metric) == tuple_size(MetricAcc) andalso
        tuple_size(Metric) > 0 andalso element(1, Metric) == element(1, MetricAcc)
->
    [Head | Tail0] = tuple_to_list(Metric),
    [Head | Tail1] = tuple_to_list(MetricAcc),
    list_to_tuple([Head | deep_sum(Tail0, Tail1)]).

zip_cluster_data(Module, Mode) ->
    zip_cluster(
        fetch_data_from_all_nodes(Module, Mode),
        Module:aggre_or_zip_init_acc()
    ).

zip_cluster([], AccIn) ->
    AccIn;
zip_cluster([{ok, {_NodeName, NodeMetric}} | Rest], AccIn) ->
    zip_cluster(
        Rest,
        maps:fold(
            fun(K, V, AccIn0) ->
                AccIn0#{
                    K => do_zip_cluster(V, ?MG(K, AccIn0))
                }
            end,
            AccIn,
            NodeMetric
        )
    );
zip_cluster([{_, _} | Rest], AccIn) ->
    zip_cluster(Rest, AccIn).

do_zip_cluster(NodeMetrics, AccIn0) ->
    lists:foldl(
        fun(K, AccIn) ->
            AccMetricL = ?MG(K, AccIn),
            NAccL = ?MG(K, NodeMetrics) ++ AccMetricL,
            AccIn#{K => NAccL}
        end,
        AccIn0,
        maps:keys(NodeMetrics)
    ).

point_to_map_fun(Key) ->
    fun({Labels, Metric}, AccIn2) ->
        LabelsKVMap = maps:from_list(Labels),
        [maps:merge(LabelsKVMap, #{Key => Metric}) | AccIn2]
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

logic_sum(N1, N2) when
    (N1 > 0 andalso N2 > 0)
->
    1;
logic_sum(_, _) ->
    0.

boolean_to_number(true) -> 1;
boolean_to_number(false) -> 0.

status_to_number(?status_connected) -> 1;
status_to_number(?status_connecting) -> 0;
status_to_number(?status_disconnected) -> 0;
status_to_number(?rm_status_stopped) -> 0;
status_to_number(_) -> 0.

metric_names(MetricWithType) when is_list(MetricWithType) ->
    [Name || {Name, _Type} <- MetricWithType].
