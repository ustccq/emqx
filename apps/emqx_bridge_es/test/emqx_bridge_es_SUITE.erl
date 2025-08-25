%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_es_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("emqx/include/emqx_config.hrl").

-import(emqx_common_test_helpers, [on_exit/1]).

-define(TYPE, elasticsearch).
-define(CA, "es.crt").

%%------------------------------------------------------------------------------
%% CT boilerplate
%%------------------------------------------------------------------------------

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    emqx_common_test_helpers:clear_screen(),
    ProxyName = "elasticsearch",
    ESHost = os:getenv("ELASTICSEARCH_HOST", "elasticsearch"),
    ESPort = list_to_integer(os:getenv("ELASTICSEARCH_PORT", "9200")),
    Apps = emqx_cth_suite:start(
        [
            emqx,
            emqx_conf,
            emqx_connector,
            emqx_bridge_es,
            emqx_bridge,
            emqx_rule_engine,
            emqx_management,
            emqx_mgmt_api_test_util:emqx_dashboard()
        ],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    wait_until_elasticsearch_is_up(ESHost, ESPort),
    [
        {apps, Apps},
        {proxy_name, ProxyName},
        {es_host, ESHost},
        {es_port, ESPort}
        | Config
    ].

es_checks() ->
    case os:getenv("IS_CI") of
        "yes" -> 10;
        _ -> 1
    end.

wait_until_elasticsearch_is_up(Host, Port) ->
    wait_until_elasticsearch_is_up(es_checks(), Host, Port).

wait_until_elasticsearch_is_up(0, Host, Port) ->
    throw({{Host, Port}, not_available});
wait_until_elasticsearch_is_up(Count, Host, Port) ->
    timer:sleep(1000),
    case emqx_common_test_helpers:is_all_tcp_servers_available([{Host, Port}]) of
        true -> ok;
        false -> wait_until_elasticsearch_is_up(Count - 1, Host, Port)
    end.

end_per_suite(Config) ->
    Apps = ?config(apps, Config),
    emqx_cth_suite:stop(Apps),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    emqx_bridge_v2_testlib:delete_all_rules(),
    emqx_bridge_v2_testlib:delete_all_bridges_and_connectors(),
    emqx_common_test_helpers:call_janitor(60_000),
    ok.

%%-------------------------------------------------------------------------------------
%% Helper fns
%%-------------------------------------------------------------------------------------

check_send_message_with_action(Topic, ActionName, ConnectorName, Expect, Line) ->
    send_message(Topic),
    %% ######################################
    %% Check if message is sent to es
    %% ######################################
    timer:sleep(500),
    check_action_metrics(ActionName, ConnectorName, Expect, Line).

mk_payload() ->
    Now = emqx_utils_calendar:now_to_rfc3339(microsecond),
    Doc = #{<<"name">> => <<"emqx">>, <<"release_date">> => Now},
    Index = <<"emqx-test-index">>,
    emqx_utils_json:encode(#{doc => Doc, index => Index}).

send_message(Topic) ->
    Payload = mk_payload(),

    ClientId = emqx_guid:to_hexstr(emqx_guid:gen()),
    {ok, Client} = emqtt:start_link([{clientid, ClientId}, {port, 1883}]),
    {ok, _} = emqtt:connect(Client),
    ok = emqtt:publish(Client, Topic, Payload, [{qos, 0}]),
    ok.

check_action_metrics(ActionName, ConnectorName, Expect, Line) ->
    ActionId = emqx_bridge_v2_testlib:make_chan_id(#{
        type => ?TYPE,
        name => ActionName,
        connector_name => ConnectorName
    }),
    ?retry(
        300,
        20,
        ?assertEqual(
            Expect,
            #{
                match => emqx_resource_metrics:matched_get(ActionId),
                success => emqx_resource_metrics:success_get(ActionId),
                failed => emqx_resource_metrics:failed_get(ActionId),
                queuing => emqx_resource_metrics:queuing_get(ActionId),
                dropped => emqx_resource_metrics:dropped_get(ActionId)
            },
            #{test_line => Line}
        )
    ).

action_config(ConnectorName) ->
    action_config(ConnectorName, _Overrides = #{}).

action_config(ConnectorName, Overrides) ->
    Cfg0 = action(ConnectorName),
    emqx_utils_maps:deep_merge(Cfg0, Overrides).

action(ConnectorName) ->
    #{
        <<"description">> => <<"My elasticsearch test action">>,
        <<"enable">> => true,
        <<"parameters">> => #{
            <<"index">> => <<"${payload.index}">>,
            <<"action">> => <<"create">>,
            <<"doc">> => <<"${payload.doc}">>,
            <<"overwrite">> => true
        },
        <<"connector">> => ConnectorName,
        <<"resource_opts">> => #{
            <<"health_check_interval">> => <<"30s">>,
            <<"query_mode">> => <<"sync">>,
            <<"metrics_flush_interval">> => <<"300ms">>
        }
    }.

server(Config) ->
    Host = ?config(es_host, Config),
    Port = ?config(es_port, Config),
    iolist_to_binary([
        Host,
        ":",
        integer_to_binary(Port)
    ]).

connector_config(Config) ->
    connector_config(_Overrides = #{}, Config).

connector_config(Overrides, Config) ->
    Defaults =
        #{
            <<"server">> => server(Config),
            <<"enable">> => true,
            <<"authentication">> => #{
                <<"password">> => <<"emqx123">>,
                <<"username">> => <<"elastic">>
            },
            <<"description">> => <<"My elasticsearch test connector">>,
            <<"connect_timeout">> => <<"15s">>,
            <<"pool_size">> => 2,
            <<"pool_type">> => <<"random">>,
            <<"enable_pipelining">> => 100,
            <<"max_inactive">> => <<"10s">>,
            <<"ssl">> => #{
                <<"enable">> => true,
                <<"hibernate_after">> => <<"5s">>,
                <<"cacertfile">> => filename:join(?config(data_dir, Config), ?CA)
            }
        },
    emqx_utils_maps:deep_merge(Defaults, Overrides).

create_connector(Name, Config) ->
    emqx_bridge_v2_testlib:create_connector_api([
        {connector_type, ?TYPE},
        {connector_name, Name},
        {connector_config, Config}
    ]).

create_action(Name, Config) ->
    emqx_bridge_v2_testlib:create_kind_api([
        {bridge_kind, action},
        {action_type, ?TYPE},
        {action_name, Name},
        {action_config, Config}
    ]).

update_action(Name, Config) ->
    emqx_bridge_v2_testlib:update_bridge_api([
        {bridge_kind, action},
        {action_type, ?TYPE},
        {action_name, Name},
        {action_config, Config}
    ]).

action_api_spec_props_for_get() ->
    #{
        <<"bridge_elasticsearch.get_bridge_v2">> :=
            #{<<"properties">> := Props}
    } =
        emqx_bridge_v2_testlib:actions_api_spec_schemas(),
    Props.

remove(Name) ->
    {204, _} = emqx_bridge_v2_testlib:delete_kind_api(action, ?TYPE, Name, #{
        query_params => #{<<"also_delete_dep_actions">> => <<"true">>}
    }),
    ok.

health_check(Type, Name) ->
    emqx_bridge_v2_testlib:force_health_check(#{
        type => Type,
        name => Name,
        resource_namespace => ?global_ns,
        kind => action
    }).

%%------------------------------------------------------------------------------
%% Test cases
%%------------------------------------------------------------------------------

%% Test sending a message to a bridge V2
t_create_message(Config) ->
    ConnectorConfig = connector_config(Config),
    ConnectorName = <<"test_connector2">>,
    {ok, _} = create_connector(ConnectorName, ConnectorConfig),
    ActionConfig = action(ConnectorName),
    ActionName = <<"test_action_1">>,
    {ok, _} = create_action(ActionName, ActionConfig),
    BridgeId = emqx_bridge_resource:bridge_id(?TYPE, ActionName),
    Rule = #{
        <<"id">> => <<"t_es">>,
        <<"sql">> => <<"SELECT\n  *\nFROM\n  \"es/#\"">>,
        <<"actions">> => [BridgeId],
        <<"description">> => <<"sink doc to elasticsearch">>
    },
    {201, _} = emqx_bridge_v2_testlib:create_rule_api2(Rule),
    %% Use the action to send a message
    Expect = #{match => 1, success => 1, dropped => 0, failed => 0, queuing => 0},
    check_send_message_with_action(<<"es/1">>, ActionName, ConnectorName, Expect, ?LINE),
    %% Create a few more bridges with the same connector and test them
    lists:foreach(
        fun(I) ->
            Seq = integer_to_binary(I),
            ActionNameStr = "test_action_" ++ integer_to_list(I),
            ActionName1 = list_to_atom(ActionNameStr),
            {ok, _} = create_action(ActionName1, ActionConfig),
            BridgeId1 = emqx_bridge_resource:bridge_id(?TYPE, ActionName1),
            Rule1 = #{
                <<"id">> => <<"rule_t_es", Seq/binary>>,
                <<"sql">> => <<"SELECT\n  *\nFROM\n  \"es/", Seq/binary, "\"">>,
                <<"actions">> => [BridgeId1],
                <<"description">> => <<"sink doc to elasticsearch">>
            },
            {201, _} = emqx_bridge_v2_testlib:create_rule_api2(Rule1),
            Topic = <<"es/", Seq/binary>>,
            check_send_message_with_action(Topic, ActionName1, ConnectorName, Expect, ?LINE),
            ok
        end,
        lists:seq(2, 10)
    ),
    ok.

t_update_message(Config) ->
    ConnectorConfig = connector_config(Config),
    {ok, _} = create_connector(update_connector, ConnectorConfig),
    ActionConfig0 = action(<<"update_connector">>),
    DocId = emqx_guid:to_hexstr(emqx_guid:gen()),
    ActionConfig1 = ActionConfig0#{
        <<"parameters">> => #{
            <<"index">> => <<"${payload.index}">>,
            <<"id">> => DocId,
            <<"max_retries">> => 0,
            <<"action">> => <<"update">>,
            <<"doc">> => <<"${payload.doc}">>
        }
    },
    {ok, _} = create_action(update_action, ActionConfig1),
    Rule = #{
        <<"id">> => <<"t_es_1">>,
        <<"sql">> => <<"SELECT\n  *\nFROM\n  \"es/#\"">>,
        <<"actions">> => [<<"elasticsearch:update_action">>],
        <<"description">> => <<"sink doc to elasticsearch">>
    },
    {201, _} = emqx_bridge_v2_testlib:create_rule_api2(Rule),
    %% failed to update a nonexistent doc
    Expect0 = #{match => 1, success => 0, dropped => 0, failed => 1, queuing => 0},
    check_send_message_with_action(<<"es/1">>, update_action, update_connector, Expect0, ?LINE),
    %% doc_as_upsert to insert a new doc
    ActionConfig2 = ActionConfig1#{
        <<"parameters">> => #{
            <<"index">> => <<"${payload.index}">>,
            <<"id">> => DocId,
            <<"action">> => <<"update">>,
            <<"doc">> => <<"${payload.doc}">>,
            <<"doc_as_upsert">> => true,
            <<"max_retries">> => 0
        }
    },
    {ok, _} = update_action(update_action, ActionConfig2),
    Expect1 = #{match => 1, success => 1, dropped => 0, failed => 0, queuing => 0},
    check_send_message_with_action(<<"es/1">>, update_action, update_connector, Expect1, ?LINE),
    %% update without doc, use msg as default
    ActionConfig3 = ActionConfig1#{
        <<"parameters">> => #{
            <<"index">> => <<"${payload.index}">>,
            <<"id">> => DocId,
            <<"action">> => <<"update">>,
            <<"max_retries">> => 0
        }
    },
    {ok, _} = update_action(update_action, ActionConfig3),
    Expect2 = #{match => 1, success => 1, dropped => 0, failed => 0, queuing => 0},
    check_send_message_with_action(<<"es/1">>, update_action, update_connector, Expect2, ?LINE),
    ok.

%% Test that we can get the status of the bridge V2
t_health_check(Config) ->
    BridgeV2Config = action(<<"test_connector3">>),
    ConnectorConfig = connector_config(Config),
    {ok, _} = create_connector(test_connector3, ConnectorConfig),
    {ok, _} = create_action(test_bridge_v2, BridgeV2Config),
    #{status := connected} = health_check(?TYPE, test_bridge_v2),
    ok = remove(test_bridge_v2),
    %% Check behaviour when bridge does not exist
    {error, bridge_not_found} = health_check(?TYPE, test_bridge_v2),
    ok.

t_bad_url(Config) ->
    ConnectorName = <<"test_connector">>,
    ActionName = <<"test_action">>,
    ActionConfig = action(<<"test_connector">>),
    ConnectorConfig0 = connector_config(Config),
    ConnectorConfig = ConnectorConfig0#{<<"server">> := <<"bad_host:9092">>},
    ?assertMatch({ok, _}, create_connector(ConnectorName, ConnectorConfig)),
    ?assertMatch({ok, _}, create_action(ActionName, ActionConfig)),
    ?assertMatch(
        {ok,
            {{_, 200, _}, _, #{
                <<"status">> := <<"disconnected">>,
                <<"status_reason">> := <<"failed_to_start_elasticsearch_bridge">>
            }}},
        emqx_bridge_v2_testlib:get_connector_api(?TYPE, ConnectorName)
    ),
    ?assertMatch(
        {ok, {{_, 200, _}, _, #{<<"status">> := <<"disconnected">>}}},
        emqx_bridge_v2_testlib:get_action_api([
            {action_type, ?TYPE},
            {action_name, ActionName}
        ])
    ),
    ok.

t_parameters_key_api_spec(_Config) ->
    ActionProps = action_api_spec_props_for_get(),
    ?assertNot(is_map_key(<<"elasticsearch">>, ActionProps), #{action_props => ActionProps}),
    ?assert(is_map_key(<<"parameters">>, ActionProps), #{action_props => ActionProps}),
    ok.

t_http_api_get(Config) ->
    ConnectorName = <<"test_connector">>,
    ActionName = <<"test_action">>,
    ActionConfig = action(ConnectorName),
    ConnectorConfig = connector_config(Config),
    ?assertMatch({ok, _}, create_connector(ConnectorName, ConnectorConfig)),
    ?assertMatch({ok, _}, create_action(ActionName, ActionConfig)),
    ?assertMatch(
        {ok,
            {{_, 200, _}, _, [
                #{
                    <<"connector">> := ConnectorName,
                    <<"description">> := <<"My elasticsearch test action">>,
                    <<"enable">> := true,
                    <<"error">> := <<>>,
                    <<"name">> := ActionName,
                    <<"node_status">> :=
                        [
                            #{
                                <<"node">> := _,
                                <<"status">> := <<"connected">>,
                                <<"status_reason">> := <<>>
                            }
                        ],
                    <<"parameters">> :=
                        #{
                            <<"action">> := <<"create">>,
                            <<"doc">> := <<"${payload.doc}">>,
                            <<"index">> := <<"${payload.index}">>,
                            <<"max_retries">> := 2,
                            <<"overwrite">> := true
                        },
                    <<"resource_opts">> := #{<<"query_mode">> := <<"sync">>},
                    <<"status">> := <<"connected">>,
                    <<"status_reason">> := <<>>,
                    <<"type">> := <<"elasticsearch">>
                }
            ]}},
        emqx_bridge_v2_testlib:list_bridges_api()
    ),
    ok.

t_rule_test_trace(Config) ->
    ConnectorName = <<"t_rule_test_trace">>,
    ActionName = <<"t_rule_test_trace">>,
    ActionConfig = action(ConnectorName),
    ConnectorConfig = connector_config(Config),
    Opts = #{payload_fn => fun mk_payload/0},
    emqx_bridge_v2_testlib:t_rule_test_trace(
        [
            {bridge_kind, action},
            {connector_type, ?TYPE},
            {connector_name, ConnectorName},
            {connector_config, ConnectorConfig},
            {action_type, ?TYPE},
            {action_name, ActionName},
            {action_config, ActionConfig}
            | Config
        ],
        Opts
    ).
