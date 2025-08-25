%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bridge_snowflake_streaming_connector_schema).

-behaviour(hocon_schema).
-behaviour(emqx_connector_examples).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").
-include("emqx_bridge_snowflake.hrl").

%% `hocon_schema' API
-export([
    namespace/0,
    roots/0,
    fields/1,
    desc/1
]).

%% `emqx_connector_examples' API
-export([
    connector_examples/1
]).

%% API
-export([]).

%%------------------------------------------------------------------------------
%% Type declarations
%%------------------------------------------------------------------------------

-define(AGGREG_CONN_SCHEMA_MOD, emqx_bridge_snowflake_aggregated_connector_schema).
-define(AGGREG_ACTION_SCHEMA_MOD, emqx_bridge_snowflake_aggregated_action_schema).

%%-------------------------------------------------------------------------------------------------
%% `hocon_schema' API
%%-------------------------------------------------------------------------------------------------

namespace() ->
    "connector_snowflake_streaming".

roots() ->
    [].

fields(Field) when
    Field == "get_connector";
    Field == "put_connector";
    Field == "post_connector"
->
    emqx_connector_schema:api_fields(Field, ?CONNECTOR_TYPE_STREAM, fields(connector_config));
fields("config_connector") ->
    emqx_connector_schema:common_fields() ++ fields(connector_config);
fields(connector_config) ->
    [
        {connect_timeout,
            mk(emqx_schema:timeout_duration_ms(), #{
                default => <<"15s">>, desc => ?DESC(?AGGREG_ACTION_SCHEMA_MOD, "connect_timeout")
            })},
        {pipelining,
            mk(pos_integer(), #{
                default => 100, desc => ?DESC(?AGGREG_ACTION_SCHEMA_MOD, "pipelining")
            })},
        {max_retries,
            mk(non_neg_integer(), #{
                default => 3, desc => ?DESC(?AGGREG_ACTION_SCHEMA_MOD, "max_retries")
            })},
        emqx_connector_schema:ehttpc_max_inactive_sc(),
        {server,
            emqx_schema:servers_sc(
                #{required => true, desc => ?DESC(?AGGREG_CONN_SCHEMA_MOD, "server")},
                ?SERVER_OPTS
            )},
        {account,
            mk(binary(), #{
                required => true,
                desc => ?DESC(?AGGREG_CONN_SCHEMA_MOD, "account"),
                validator => fun emqx_bridge_snowflake_lib:account_id_validator/1
            })},
        {pipe_user,
            mk(binary(), #{
                required => true,
                desc => ?DESC(?AGGREG_ACTION_SCHEMA_MOD, "pipe_user")
            })},
        {private_key,
            emqx_schema_secret:mk(#{
                required => true,
                desc => ?DESC(?AGGREG_ACTION_SCHEMA_MOD, "private_key")
            })},
        {private_key_password,
            emqx_schema_secret:mk(#{
                required => false,
                desc => ?DESC(?AGGREG_CONN_SCHEMA_MOD, "private_key_password")
            })},
        {proxy,
            mk(
                hoconsc:union([none, hoconsc:ref(?MODULE, proxy_config)]),
                #{default => none, desc => ?DESC(?AGGREG_CONN_SCHEMA_MOD, "proxy_config")}
            )}
    ] ++
        emqx_connector_schema:resource_opts() ++
        emqx_connector_schema_lib:ssl_fields();
fields(proxy_config) ->
    [
        {host,
            mk(binary(), #{
                required => true,
                desc => ?DESC(?AGGREG_CONN_SCHEMA_MOD, "proxy_config_host")
            })},
        {port,
            mk(emqx_schema:port_number(), #{
                required => true,
                desc => ?DESC(?AGGREG_CONN_SCHEMA_MOD, "proxy_config_port")
            })}
    ].

desc("config_connector") ->
    ?DESC("config_connector");
desc(resource_opts) ->
    ?DESC(emqx_resource_schema, resource_opts);
desc(proxy_config) ->
    ?DESC(?AGGREG_CONN_SCHEMA_MOD, "proxy_config");
desc(_Name) ->
    undefined.

%%-------------------------------------------------------------------------------------------------
%% `emqx_connector_examples' API
%%-------------------------------------------------------------------------------------------------

connector_examples(Method) ->
    [
        #{
            <<"snowflake">> => #{
                summary => <<"Snowflake Connector">>,
                value => connector_example(Method)
            }
        }
    ].

connector_example(get) ->
    maps:merge(
        connector_example(put),
        #{
            status => <<"connected">>,
            node_status => [
                #{
                    node => <<"emqx@localhost">>,
                    status => <<"connected">>
                }
            ]
        }
    );
connector_example(post) ->
    maps:merge(
        connector_example(put),
        #{
            type => atom_to_binary(?CONNECTOR_TYPE_AGGREG),
            name => <<"my_connector">>
        }
    );
connector_example(put) ->
    #{
        enable => true,
        description => <<"My connector">>,
        server => <<"myorg-myaccount.snowflakecomputing.com">>,
        account => <<"myorg-myaccount">>,
        username => <<"admin">>,
        password => <<"******">>,
        dsn => <<"snowflake">>,
        pool_size => 8,
        resource_opts => #{
            health_check_interval => <<"45s">>,
            start_after_created => true,
            start_timeout => <<"5s">>
        }
    }.

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%%------------------------------------------------------------------------------
%% Internal fns
%%------------------------------------------------------------------------------

mk(Type, Meta) -> hoconsc:mk(Type, Meta).
