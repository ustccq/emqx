%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_auth_cache_schema).

-include_lib("hocon/include/hoconsc.hrl").

-export([
    namespace/0,
    roots/0,
    fields/1,
    desc/1
]).

-export([
    fill_defaults/1,
    default_config/0
]).

-export([
    cache_settings_example/0,
    metrics_example/0
]).

namespace() -> auth_cache.

%% @doc auth cache schema is not exported but directly used
roots() -> [].

fields(config) ->
    [
        {enable, mk(boolean(), #{desc => ?DESC(enable), default => false})},
        {cache_ttl,
            mk(emqx_schema:timeout_duration_ms(), #{
                desc => ?DESC(cache_ttl), default => <<"1m">>
            })},
        {cleanup_interval,
            mk(emqx_schema:timeout_duration_ms(), #{
                desc => ?DESC(cleanup_interval),
                default => <<"1m">>,
                importance => ?IMPORTANCE_HIDDEN
            })},
        {stat_update_interval,
            mk(emqx_schema:timeout_duration_ms(), #{
                desc => ?DESC(stat_update_interval),
                default => <<"5s">>,
                importance => ?IMPORTANCE_HIDDEN
            })},
        {max_count,
            mk(hoconsc:union([unlimited, non_neg_integer()]), #{
                desc => ?DESC(max_count),
                default => 1000000
            })},
        {max_memory,
            mk(hoconsc:union([unlimited, emqx_schema:bytesize()]), #{
                desc => ?DESC(max_memory),
                default => <<"100MB">>
            })}
    ];
%% These fields are not used for the configuration.
%% They describe API responses.
fields(rate) ->
    [
        {rate, ?HOCON(float(), #{desc => ?DESC("rate")})},
        {rate_max, ?HOCON(float(), #{desc => ?DESC("rate_max")})},
        {rate_last5m, ?HOCON(float(), #{desc => ?DESC("rate_last5m")})}
    ];
fields(counter) ->
    [
        {value, ?HOCON(integer(), #{desc => ?DESC("counter_value")})},
        {rate, ?HOCON(?R_REF(rate), #{desc => ?DESC("counter_rate")})}
    ];
fields(metrics) ->
    [
        {hits, ?HOCON(?R_REF(counter), #{desc => ?DESC("metric_hits")})},
        {misses, ?HOCON(?R_REF(counter), #{desc => ?DESC("metric_misses")})},
        {inserts, ?HOCON(?R_REF(counter), #{desc => ?DESC("metric_inserts")})},
        {count, ?HOCON(integer(), #{desc => ?DESC("metric_size")})},
        {memory, ?HOCON(integer(), #{desc => ?DESC("metric_memory")})}
    ];
fields(node_metrics) ->
    [
        {node, ?HOCON(binary(), #{desc => ?DESC("node"), example => "emqx@127.0.0.1"})},
        {metrics, ?HOCON(?R_REF(metrics), #{desc => ?DESC("metrics")})}
    ];
fields(status) ->
    [
        {metrics, ?HOCON(?R_REF(metrics), #{desc => ?DESC("status_metrics")})},
        {node_metrics,
            ?HOCON(?ARRAY(?R_REF(node_metrics)), #{desc => ?DESC("status_node_metrics")})}
    ].

desc(config) -> ?DESC(auth_cache_config);
desc(metrics) -> ?DESC(auth_cache_metrics);
desc(_) -> undefined.

fill_defaults(Config) ->
    emqx_schema:fill_defaults_for_type(?R_REF(config), Config).

default_config() ->
    #{
        <<"enable">> => false
    }.

%%------------------------------------------------------------------------------
%% Data examples
%%------------------------------------------------------------------------------

cache_settings_example() ->
    #{
        enable => true,
        cache_ttl => <<"1m">>,
        cleanup_interval => <<"1m">>,
        stat_update_interval => <<"1m">>,
        max_count => 100000,
        max_memory => <<"100MB">>
    }.

metrics_example() ->
    #{
        metrics =>
            #{
                memory => 1704,
                size => 0,
                hits =>
                    #{value => 0, rate => #{max => 0.0, current => 0.0, last5m => 0.0}},
                inserts =>
                    #{value => 0, rate => #{max => 0.0, current => 0.0, last5m => 0.0}},
                misses =>
                    #{value => 1, rate => #{max => 0.0, current => 0.0, last5m => 0.0}}
            },
        node_metrics =>
            [
                #{
                    node => <<"test@127.0.0.1">>,
                    metrics =>
                        #{
                            memory => 1704,
                            size => 0,
                            hits =>
                                #{
                                    value => 0,
                                    rate => #{max => 0.0, current => 0.0, last5m => 0.0}
                                },
                            inserts =>
                                #{
                                    value => 0,
                                    rate => #{max => 0.0, current => 0.0, last5m => 0.0}
                                },
                            misses =>
                                #{
                                    value => 1,
                                    rate => #{max => 0.0, current => 0.0, last5m => 0.0}
                                }
                        }
                }
            ]
    }.

%%------------------------------------------------------------------------------
%% Internal Functions
%%------------------------------------------------------------------------------

mk(Type, Meta) -> hoconsc:mk(Type, Meta).
