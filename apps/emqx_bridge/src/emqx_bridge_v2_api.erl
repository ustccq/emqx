%%--------------------------------------------------------------------
%% Copyright (c) 2023-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bridge_v2_api).

-behaviour(minirest_api).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").
-include_lib("hocon/include/hocon.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx_utils/include/emqx_http_api.hrl").
-include_lib("emqx_bridge/include/emqx_bridge.hrl").
-include_lib("emqx_bridge/include/emqx_bridge_proto.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("emqx/include/emqx_config.hrl").

-import(hoconsc, [mk/2, array/1, enum/1]).
-import(emqx_utils, [redact/1]).

-define(ROOT_KEY_ACTIONS, actions).
-define(ROOT_KEY_SOURCES, sources).

%% Swagger specs from hocon schema
-export([
    api_spec/0,
    check_api_schema/2,
    paths/0,
    schema/1,
    namespace/0,
    fields/1
]).

%% API callbacks : actions
-export([
    '/actions'/2,
    '/actions/:id'/2,
    '/actions/:id/metrics'/2,
    '/actions/:id/metrics/reset'/2,
    '/actions/:id/enable/:enable'/2,
    '/actions/:id/:operation'/2,
    '/nodes/:node/actions/:id/:operation'/2,
    '/actions_probe'/2,
    '/actions_summary'/2,
    '/action_types'/2
]).
%% API callbacks : sources
-export([
    '/sources'/2,
    '/sources/:id'/2,
    '/sources/:id/metrics'/2,
    '/sources/:id/metrics/reset'/2,
    '/sources/:id/enable/:enable'/2,
    '/sources/:id/:operation'/2,
    '/nodes/:node/sources/:id/:operation'/2,
    '/sources_probe'/2,
    '/sources_summary'/2,
    '/source_types'/2
]).

%% BpAPI / RPC Targets
-export([
    lookup_from_local_node/2,
    get_metrics_from_local_node/2,
    lookup_from_local_node_v6/3,
    get_metrics_from_local_node_v6/3,
    summary_from_local_node_v7/1,
    wait_for_ready_local_node_v7/3,

    lookup_v8/4,
    summary_v8/2,
    wait_for_ready_v8/4,
    get_metrics_v8/4
]).

%% Internal exports; used by rule engine api
-export([do_handle_summary/2]).

-define(BPAPI_NAME, emqx_bridge).

-define(BRIDGE_NOT_FOUND(BRIDGE_TYPE, BRIDGE_NAME),
    ?NOT_FOUND(
        <<"Bridge lookup failed: bridge named '", (bin(BRIDGE_NAME))/binary, "' of type ",
            (bin(BRIDGE_TYPE))/binary, " does not exist.">>
    )
).

-define(TRY_PARSE_ID(ID, EXPR),
    try emqx_bridge_resource:parse_bridge_id(Id, #{atom_name => false}) of
        #{type := BridgeType, name := BridgeName} ->
            EXPR
    catch
        throw:#{reason := Reason} ->
            ?NOT_FOUND(<<"Invalid bridge ID, ", Reason/binary>>)
    end
).

-type maybe_namespace() :: ?global_ns | binary().

namespace() -> "actions_and_sources".

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => fun ?MODULE:check_api_schema/2}).

paths() ->
    [
        %%=============
        %% Actions
        %%=============
        "/actions",
        "/actions/:id",
        "/actions/:id/enable/:enable",
        "/actions/:id/:operation",
        "/nodes/:node/actions/:id/:operation",
        %% Caveat: metrics paths must come *after* `/:operation', otherwise minirest will
        %% try to match the latter first, trying to interpret `metrics' as an operation...
        "/actions/:id/metrics",
        "/actions/:id/metrics/reset",
        "/actions_probe",
        "/actions_summary",
        "/action_types",
        %%=============
        %% Sources
        %%=============
        "/sources",
        "/sources/:id",
        "/sources/:id/enable/:enable",
        "/sources/:id/:operation",
        "/nodes/:node/sources/:id/:operation",
        %% %% Caveat: metrics paths must come *after* `/:operation', otherwise minirest will
        %% %% try to match the latter first, trying to interpret `metrics' as an operation...
        "/sources/:id/metrics",
        "/sources/:id/metrics/reset",
        "/sources_probe",
        "/sources_summary",
        "/source_types"
    ].

error_schema(Code, Message) ->
    error_schema(Code, Message, _ExtraFields = []).

error_schema(Code, Message, ExtraFields) when is_atom(Code) ->
    error_schema([Code], Message, ExtraFields);
error_schema(Codes, DESC, ExtraFields) when is_list(Codes) andalso is_tuple(DESC) ->
    ExtraFields ++ emqx_dashboard_swagger:error_codes(Codes, DESC).

actions_get_response_body_schema() ->
    emqx_dashboard_swagger:schema_with_examples(
        emqx_bridge_v2_schema:actions_get_response(),
        bridge_info_examples(get, ?ROOT_KEY_ACTIONS)
    ).

sources_get_response_body_schema() ->
    emqx_dashboard_swagger:schema_with_examples(
        emqx_bridge_v2_schema:sources_get_response(),
        bridge_info_examples(get, ?ROOT_KEY_SOURCES)
    ).

bridge_info_examples(Method, ?ROOT_KEY_ACTIONS) ->
    emqx_bridge_v2_schema:actions_examples(Method);
bridge_info_examples(Method, ?ROOT_KEY_SOURCES) ->
    emqx_bridge_v2_schema:sources_examples(Method).

bridge_info_array_example(Method, ConfRootKey) ->
    lists:map(
        fun(#{value := Config}) -> Config end,
        maps:values(bridge_info_examples(Method, ConfRootKey))
    ).

summary_response_example(ConfRootKey) ->
    {TypeEx, ExName} =
        case ConfRootKey of
            ?ROOT_KEY_SOURCES -> {<<"source_type">>, <<"Source">>};
            ?ROOT_KEY_ACTIONS -> {<<"action_type">>, <<"Action">>}
        end,
    [
        #{
            enable => true,
            name => <<"my", ExName/binary>>,
            type => TypeEx,
            created_at => 1736512728666,
            last_modified_at => 1736512728666,
            node_status => [
                #{
                    node => <<"emqx@127.0.0.1">>,
                    status => <<"connected">>,
                    status_reason => <<"">>
                }
            ],
            rules => [<<"rule1">>, <<"rule2">>],
            status => <<"connected">>,
            status_reason => <<"">>
        }
    ].

param_path_id() ->
    {id,
        mk(
            binary(),
            #{
                in => path,
                required => true,
                example => <<"http:my_http_action">>,
                desc => ?DESC("desc_param_path_id")
            }
        )}.

param_qs_delete_cascade() ->
    {also_delete_dep_actions,
        mk(
            boolean(),
            #{
                in => query,
                required => false,
                default => false,
                desc => ?DESC("desc_qs_also_delete_dep_actions")
            }
        )}.

param_path_operation_cluster() ->
    {operation,
        mk(
            enum([start]),
            #{
                in => path,
                required => true,
                example => <<"start">>,
                desc => ?DESC("desc_param_path_operation_cluster")
            }
        )}.

param_path_operation_on_node() ->
    {operation,
        mk(
            enum([start]),
            #{
                in => path,
                required => true,
                example => <<"start">>,
                desc => ?DESC("desc_param_path_operation_on_node")
            }
        )}.

param_path_node() ->
    {node,
        mk(
            binary(),
            #{
                in => path,
                required => true,
                example => <<"emqx@127.0.0.1">>,
                desc => ?DESC("desc_param_path_node")
            }
        )}.

param_path_enable() ->
    {enable,
        mk(
            boolean(),
            #{
                in => path,
                required => true,
                desc => ?DESC("desc_param_path_enable"),
                example => true
            }
        )}.

%%================================================================================
%% Actions
%%================================================================================
schema("/actions") ->
    #{
        'operationId' => '/actions',
        get => #{
            tags => [<<"actions">>],
            summary => <<"List Actions">>,
            description => ?DESC("desc_api1"),
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_example(
                    array(emqx_bridge_v2_schema:actions_get_response()),
                    bridge_info_array_example(get, ?ROOT_KEY_ACTIONS)
                )
            }
        },
        post => #{
            tags => [<<"actions">>],
            summary => <<"Create Action">>,
            description => ?DESC("desc_api2"),
            'requestBody' => emqx_dashboard_swagger:schema_with_examples(
                emqx_bridge_v2_schema:actions_post_request(),
                bridge_info_examples(post, ?ROOT_KEY_ACTIONS)
            ),
            responses => #{
                201 => actions_get_response_body_schema(),
                400 => error_schema('ALREADY_EXISTS', ?DESC("action_already_exists"))
            }
        }
    };
schema("/actions/:id") ->
    #{
        'operationId' => '/actions/:id',
        get => #{
            tags => [<<"actions">>],
            summary => <<"Get Action">>,
            description => ?DESC("desc_api3"),
            parameters => [param_path_id()],
            responses => #{
                200 => actions_get_response_body_schema(),
                404 => error_schema('NOT_FOUND', ?DESC("action_not_found"))
            }
        },
        put => #{
            tags => [<<"actions">>],
            summary => <<"Update Action">>,
            description => ?DESC("desc_api4"),
            parameters => [param_path_id()],
            'requestBody' => emqx_dashboard_swagger:schema_with_examples(
                emqx_bridge_v2_schema:actions_put_request(),
                bridge_info_examples(put, ?ROOT_KEY_ACTIONS)
            ),
            responses => #{
                200 => actions_get_response_body_schema(),
                404 => error_schema('NOT_FOUND', ?DESC("action_not_found")),
                400 => error_schema('BAD_REQUEST', ?DESC("update_action_failed")),
                503 => error_schema('SERVICE_UNAVAILABLE', ?DESC("service_unavailable"))
            }
        },
        delete => #{
            tags => [<<"actions">>],
            summary => <<"Delete Action">>,
            description => ?DESC("desc_api5"),
            parameters => [param_path_id(), param_qs_delete_cascade()],
            responses => #{
                204 => ?DESC("OK"),
                400 => error_schema(
                    'BAD_REQUEST',
                    ?DESC("dependent_rules_error_msg"),
                    [{rules, mk(array(string()), #{desc => ?DESC("dependent_rules_ids")})}]
                ),
                404 => error_schema('NOT_FOUND', ?DESC("action_not_found")),
                503 => error_schema('SERVICE_UNAVAILABLE', ?DESC("service_unavailable"))
            }
        }
    };
schema("/actions/:id/metrics") ->
    #{
        'operationId' => '/actions/:id/metrics',
        get => #{
            tags => [<<"actions">>],
            summary => <<"Get Action Metrics">>,
            description => ?DESC("desc_bridge_metrics"),
            parameters => [param_path_id()],
            responses => #{
                200 => emqx_bridge_schema:metrics_fields(),
                404 => error_schema('NOT_FOUND', ?DESC("action_not_found"))
            }
        }
    };
schema("/actions/:id/metrics/reset") ->
    #{
        'operationId' => '/actions/:id/metrics/reset',
        put => #{
            tags => [<<"actions">>],
            summary => <<"Reset Action Metrics">>,
            description => ?DESC("desc_api6"),
            parameters => [param_path_id()],
            responses => #{
                204 => ?DESC("OK"),
                404 => error_schema('NOT_FOUND', ?DESC("action_not_found"))
            }
        }
    };
schema("/actions/:id/enable/:enable") ->
    #{
        'operationId' => '/actions/:id/enable/:enable',
        put =>
            #{
                tags => [<<"actions">>],
                summary => <<"Enable or Disable Action">>,
                desc => ?DESC("desc_enable_bridge"),
                parameters => [param_path_id(), param_path_enable()],
                responses =>
                    #{
                        204 => ?DESC("OK"),
                        404 => error_schema('NOT_FOUND', ?DESC("action_not_found")),
                        503 => error_schema('SERVICE_UNAVAILABLE', ?DESC("service_unavailable"))
                    }
            }
    };
schema("/actions/:id/:operation") ->
    #{
        'operationId' => '/actions/:id/:operation',
        post => #{
            tags => [<<"actions">>],
            summary => <<"Manually Start an Action">>,
            description => ?DESC("desc_api7"),
            parameters => [
                param_path_id(),
                param_path_operation_cluster()
            ],
            responses => #{
                204 => ?DESC("OK"),
                400 => error_schema(
                    'BAD_REQUEST', ?DESC("operation_failed")
                ),
                404 => error_schema('NOT_FOUND', ?DESC("action_not_found")),
                501 => error_schema('NOT_IMPLEMENTED', ?DESC("not_implemented")),
                503 => error_schema('SERVICE_UNAVAILABLE', ?DESC("service_unavailable"))
            }
        }
    };
schema("/nodes/:node/actions/:id/:operation") ->
    #{
        'operationId' => '/nodes/:node/actions/:id/:operation',
        post => #{
            tags => [<<"actions">>],
            summary => <<"Manually Start an Action on a Given Node">>,
            description => ?DESC("desc_api8"),
            parameters => [
                param_path_node(),
                param_path_id(),
                param_path_operation_on_node()
            ],
            responses => #{
                204 => ?DESC("OK"),
                400 => error_schema('BAD_REQUEST', ?DESC("operation_failed")),
                404 => error_schema('NOT_FOUND', ?DESC("action_not_found")),
                501 => error_schema('NOT_IMPLEMENTED', ?DESC("not_implemented")),
                503 => error_schema('SERVICE_UNAVAILABLE', ?DESC("service_unavailable"))
            }
        }
    };
schema("/actions_probe") ->
    #{
        'operationId' => '/actions_probe',
        post => #{
            tags => [<<"actions">>],
            desc => ?DESC("desc_api9"),
            summary => <<"Test Creating Action">>,
            'requestBody' => emqx_dashboard_swagger:schema_with_examples(
                emqx_bridge_v2_schema:actions_post_request(),
                bridge_info_examples(post, ?ROOT_KEY_ACTIONS)
            ),
            responses => #{
                204 => ?DESC("OK"),
                400 => error_schema(['TEST_FAILED'], ?DESC("action_test_failed"))
            }
        }
    };
schema("/actions_summary") ->
    #{
        'operationId' => '/actions_summary',
        get => #{
            tags => [<<"actions">>],
            summary => <<"Summarize Actions">>,
            description => ?DESC("actions_summary"),
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_example(
                    array(hoconsc:ref(?MODULE, response_summary)),
                    summary_response_example(?ROOT_KEY_ACTIONS)
                )
            }
        }
    };
schema("/action_types") ->
    #{
        'operationId' => '/action_types',
        get => #{
            tags => [<<"actions">>],
            desc => ?DESC("desc_api10"),
            summary => <<"List Available Action Types">>,
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_examples(
                    array(emqx_bridge_v2_schema:action_types_sc()),
                    #{
                        <<"types">> =>
                            #{
                                summary => <<"Action Types">>,
                                value => emqx_bridge_v2_schema:action_types()
                            }
                    }
                )
            }
        }
    };
%%================================================================================
%% Sources
%%================================================================================
schema("/sources") ->
    #{
        'operationId' => '/sources',
        get => #{
            tags => [<<"sources">>],
            summary => <<"List Sources">>,
            description => ?DESC("desc_api1"),
            responses => #{
                %% FIXME: examples
                200 => emqx_dashboard_swagger:schema_with_example(
                    array(emqx_bridge_v2_schema:sources_get_response()),
                    bridge_info_array_example(get, ?ROOT_KEY_SOURCES)
                )
            }
        },
        post => #{
            tags => [<<"sources">>],
            summary => <<"Create Source">>,
            description => ?DESC("desc_api2"),
            %% FIXME: examples
            'requestBody' => emqx_dashboard_swagger:schema_with_examples(
                emqx_bridge_v2_schema:sources_post_request(),
                bridge_info_examples(post, ?ROOT_KEY_SOURCES)
            ),
            responses => #{
                201 => sources_get_response_body_schema(),
                400 => error_schema('ALREADY_EXISTS', ?DESC("source_already_exists"))
            }
        }
    };
schema("/sources/:id") ->
    #{
        'operationId' => '/sources/:id',
        get => #{
            tags => [<<"sources">>],
            summary => <<"Get Source">>,
            description => ?DESC("desc_api3"),
            parameters => [param_path_id()],
            responses => #{
                200 => sources_get_response_body_schema(),
                404 => error_schema('NOT_FOUND', ?DESC("source_not_found"))
            }
        },
        put => #{
            tags => [<<"sources">>],
            summary => <<"Update Source">>,
            description => ?DESC("desc_api4"),
            parameters => [param_path_id()],
            'requestBody' => emqx_dashboard_swagger:schema_with_examples(
                emqx_bridge_v2_schema:sources_put_request(),
                bridge_info_examples(put, ?ROOT_KEY_SOURCES)
            ),
            responses => #{
                200 => sources_get_response_body_schema(),
                404 => error_schema('NOT_FOUND', ?DESC("source_not_found")),
                400 => error_schema('BAD_REQUEST', ?DESC("update_source_failed")),
                503 => error_schema('SERVICE_UNAVAILABLE', ?DESC("service_unavailable"))
            }
        },
        delete => #{
            tags => [<<"sources">>],
            summary => <<"Delete Source">>,
            description => ?DESC("desc_api5"),
            parameters => [param_path_id(), param_qs_delete_cascade()],
            responses => #{
                204 => ?DESC("OK"),
                400 => error_schema(
                    'BAD_REQUEST',
                    ?DESC("dependent_rules_error_msg"),
                    [{rules, mk(array(string()), #{desc => ?DESC("dependent_rules_ids")})}]
                ),
                404 => error_schema('NOT_FOUND', ?DESC("source_not_found")),
                503 => error_schema('SERVICE_UNAVAILABLE', ?DESC("service_unavailable"))
            }
        }
    };
schema("/sources/:id/metrics") ->
    #{
        'operationId' => '/sources/:id/metrics',
        get => #{
            tags => [<<"sources">>],
            summary => <<"Get Source Metrics">>,
            description => ?DESC("desc_bridge_metrics"),
            parameters => [param_path_id()],
            responses => #{
                200 => emqx_bridge_schema:metrics_fields(),
                404 => error_schema('NOT_FOUND', ?DESC("source_not_found"))
            }
        }
    };
schema("/sources/:id/metrics/reset") ->
    #{
        'operationId' => '/sources/:id/metrics/reset',
        put => #{
            tags => [<<"sources">>],
            summary => <<"Reset Source Metrics">>,
            description => ?DESC("desc_api6"),
            parameters => [param_path_id()],
            responses => #{
                204 => ?DESC("OK"),
                404 => error_schema('NOT_FOUND', ?DESC("source_not_found"))
            }
        }
    };
schema("/sources/:id/enable/:enable") ->
    #{
        'operationId' => '/sources/:id/enable/:enable',
        put =>
            #{
                tags => [<<"sources">>],
                summary => <<"Enable or Disable Source">>,
                desc => ?DESC("desc_enable_bridge"),
                parameters => [param_path_id(), param_path_enable()],
                responses =>
                    #{
                        204 => ?DESC("OK"),
                        404 => error_schema('NOT_FOUND', ?DESC("source_not_found")),
                        503 => error_schema('SERVICE_UNAVAILABLE', ?DESC("service_unavailable"))
                    }
            }
    };
schema("/sources/:id/:operation") ->
    #{
        'operationId' => '/sources/:id/:operation',
        post => #{
            tags => [<<"sources">>],
            summary => <<"Manually Start a Source">>,
            description => ?DESC("desc_api7"),
            parameters => [
                param_path_id(),
                param_path_operation_cluster()
            ],
            responses => #{
                204 => ?DESC("OK"),
                400 => error_schema('BAD_REQUEST', ?DESC("operation_failed")),
                404 => error_schema('NOT_FOUND', ?DESC("source_not_found")),
                501 => error_schema('NOT_IMPLEMENTED', ?DESC("not_implemented")),
                503 => error_schema('SERVICE_UNAVAILABLE', ?DESC("service_unavailable"))
            }
        }
    };
schema("/nodes/:node/sources/:id/:operation") ->
    #{
        'operationId' => '/nodes/:node/sources/:id/:operation',
        post => #{
            tags => [<<"sources">>],
            summary => <<"Manually Start a Source on a Given Node">>,
            description => ?DESC("desc_api8"),
            parameters => [
                param_path_node(),
                param_path_id(),
                param_path_operation_on_node()
            ],
            responses => #{
                204 => ?DESC("OK"),
                400 => error_schema('BAD_REQUEST', ?DESC("operation_failed")),
                404 => error_schema('NOT_FOUND', ?DESC("source_not_found")),
                501 => error_schema('NOT_IMPLEMENTED', ?DESC("not_implemented")),
                503 => error_schema('SERVICE_UNAVAILABLE', ?DESC("service_unavailable"))
            }
        }
    };
schema("/sources_probe") ->
    #{
        'operationId' => '/sources_probe',
        post => #{
            tags => [<<"sources">>],
            desc => ?DESC("desc_api9"),
            summary => <<"Test Creating Source">>,
            'requestBody' => emqx_dashboard_swagger:schema_with_examples(
                emqx_bridge_v2_schema:sources_post_request(),
                bridge_info_examples(post, ?ROOT_KEY_SOURCES)
            ),
            responses => #{
                204 => ?DESC("OK"),
                400 => error_schema(['TEST_FAILED'], ?DESC("source_test_failed"))
            }
        }
    };
schema("/sources_summary") ->
    #{
        'operationId' => '/sources_summary',
        get => #{
            tags => [<<"sources">>],
            summary => <<"Summarize Sources">>,
            description => ?DESC("sources_summary"),
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_example(
                    array(hoconsc:ref(?MODULE, response_summary)),
                    summary_response_example(?ROOT_KEY_SOURCES)
                )
            }
        }
    };
schema("/source_types") ->
    #{
        'operationId' => '/source_types',
        get => #{
            tags => [<<"sources">>],
            desc => ?DESC("desc_api11"),
            summary => <<"List Available Source Types">>,
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_examples(
                    array(emqx_bridge_v2_schema:source_types_sc()),
                    #{
                        <<"types">> =>
                            #{
                                summary => <<"Source types">>,
                                value => emqx_bridge_v2_schema:source_types()
                            }
                    }
                )
            }
        }
    }.

fields(response_node_status) ->
    [
        {node, mk(binary(), #{})},
        {status, mk(binary(), #{})},
        {status_reason, mk(binary(), #{})}
    ];
fields(response_summary) ->
    [
        {enable, mk(boolean(), #{})},
        {name, mk(binary(), #{})},
        {type, mk(binary(), #{})},
        {description, mk(binary(), #{})},
        {created_at, mk(integer(), #{})},
        {last_modified_at, mk(integer(), #{})},
        {node_status, mk(array(hoconsc:ref(?MODULE, response_node_status)), #{})},
        {rules, mk(array(binary()), #{})},
        {status, mk(binary(), #{})},
        {status_reason, mk(binary(), #{})}
    ].

%%------------------------------------------------------------------------------

check_api_schema(Request, ReqMeta = #{path := "/actions/:id", method := put}) ->
    BridgeId = emqx_utils_maps:deep_get([bindings, id], Request),
    try emqx_bridge_resource:parse_bridge_id(BridgeId, #{atom_name => false}) of
        %% NOTE
        %% Bridge type is known, refine the API schema to get more specific error messages.
        #{type := BridgeType} ->
            Schema = emqx_bridge_v2_schema:action_api_schema("put", BridgeType),
            emqx_dashboard_swagger:filter_check_request(Request, refine_api_schema(Schema, ReqMeta))
    catch
        throw:#{reason := Reason} ->
            ?NOT_FOUND(<<"Invalid bridge ID, ", Reason/binary>>)
    end;
check_api_schema(Request, ReqMeta = #{path := "/sources/:id", method := put}) ->
    SourceId = emqx_utils_maps:deep_get([bindings, id], Request),
    try emqx_bridge_resource:parse_bridge_id(SourceId, #{atom_name => false}) of
        %% NOTE
        %% Source type is known, refine the API schema to get more specific error messages.
        #{type := BridgeType} ->
            Schema = emqx_bridge_v2_schema:source_api_schema("put", BridgeType),
            emqx_dashboard_swagger:filter_check_request(Request, refine_api_schema(Schema, ReqMeta))
    catch
        throw:#{reason := Reason} ->
            ?NOT_FOUND(<<"Invalid source ID, ", Reason/binary>>)
    end;
check_api_schema(Request, ReqMeta) ->
    emqx_dashboard_swagger:filter_check_request(Request, ReqMeta).

refine_api_schema(Schema, ReqMeta = #{path := Path, method := Method}) ->
    Spec = maps:get(Method, schema(Path)),
    SpecRefined = Spec#{'requestBody' => Schema},
    ReqMeta#{apispec => SpecRefined}.

%%------------------------------------------------------------------------------
%% Thin Handlers
%%------------------------------------------------------------------------------
%%================================================================================
%% Actions
%%================================================================================
'/actions'(post, #{body := #{<<"type">> := BridgeType, <<"name">> := BridgeName} = Conf0} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_create(Namespace, ?ROOT_KEY_ACTIONS, BridgeType, BridgeName, Conf0);
'/actions'(get, Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_list(Namespace, ?ROOT_KEY_ACTIONS).

'/actions/:id'(get, #{bindings := #{id := Id}} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    ?TRY_PARSE_ID(
        Id, lookup_from_all_nodes(Namespace, ?ROOT_KEY_ACTIONS, BridgeType, BridgeName, 200)
    );
'/actions/:id'(put, #{bindings := #{id := Id}, body := Conf0} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_update(Namespace, ?ROOT_KEY_ACTIONS, Id, Conf0);
'/actions/:id'(delete, #{bindings := #{id := Id}, query_string := Qs} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_delete(Namespace, ?ROOT_KEY_ACTIONS, Id, Qs).

'/actions/:id/metrics'(get, #{bindings := #{id := Id}} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    ?TRY_PARSE_ID(
        Id, get_metrics_from_all_nodes(Namespace, ?ROOT_KEY_ACTIONS, BridgeType, BridgeName)
    ).

'/actions/:id/metrics/reset'(put, #{bindings := #{id := Id}} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_reset_metrics(Namespace, ?ROOT_KEY_ACTIONS, Id).

'/actions/:id/enable/:enable'(put, #{bindings := #{id := Id, enable := Enable}} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_disable_enable(Namespace, ?ROOT_KEY_ACTIONS, Id, Enable).

'/actions/:id/:operation'(
    post,
    #{
        bindings :=
            #{id := Id, operation := Op}
    } = Req
) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_operation(Namespace, ?ROOT_KEY_ACTIONS, Id, Op).

'/nodes/:node/actions/:id/:operation'(
    post,
    #{
        bindings :=
            #{id := Id, operation := Op, node := Node}
    } = Req
) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_node_operation(Namespace, ?ROOT_KEY_ACTIONS, Node, Id, Op).

'/actions_probe'(post, Request) ->
    Namespace = emqx_dashboard:get_namespace(Request),
    handle_probe(Namespace, ?ROOT_KEY_ACTIONS, Request).

'/actions_summary'(get, Request) ->
    Namespace = emqx_dashboard:get_namespace(Request),
    handle_summary(Namespace, ?ROOT_KEY_ACTIONS).

'/action_types'(get, _Request) ->
    ?OK(emqx_bridge_v2_schema:action_types()).
%%================================================================================
%% Sources
%%================================================================================
'/sources'(post, #{body := #{<<"type">> := BridgeType, <<"name">> := BridgeName} = Conf0} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_create(Namespace, ?ROOT_KEY_SOURCES, BridgeType, BridgeName, Conf0);
'/sources'(get, Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_list(Namespace, ?ROOT_KEY_SOURCES).

'/sources/:id'(get, #{bindings := #{id := Id}} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    ?TRY_PARSE_ID(
        Id, lookup_from_all_nodes(Namespace, ?ROOT_KEY_SOURCES, BridgeType, BridgeName, 200)
    );
'/sources/:id'(put, #{bindings := #{id := Id}, body := Conf0} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_update(Namespace, ?ROOT_KEY_SOURCES, Id, Conf0);
'/sources/:id'(delete, #{bindings := #{id := Id}, query_string := Qs} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_delete(Namespace, ?ROOT_KEY_SOURCES, Id, Qs).

'/sources/:id/metrics'(get, #{bindings := #{id := Id}} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    ?TRY_PARSE_ID(
        Id, get_metrics_from_all_nodes(Namespace, ?ROOT_KEY_SOURCES, BridgeType, BridgeName)
    ).

'/sources/:id/metrics/reset'(put, #{bindings := #{id := Id}} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_reset_metrics(Namespace, ?ROOT_KEY_SOURCES, Id).

'/sources/:id/enable/:enable'(put, #{bindings := #{id := Id, enable := Enable}} = Req) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_disable_enable(Namespace, ?ROOT_KEY_SOURCES, Id, Enable).

'/sources/:id/:operation'(
    post,
    #{
        bindings :=
            #{id := Id, operation := Op}
    } = Req
) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_operation(Namespace, ?ROOT_KEY_SOURCES, Id, Op).

'/nodes/:node/sources/:id/:operation'(
    post,
    #{
        bindings :=
            #{id := Id, operation := Op, node := Node}
    } = Req
) ->
    Namespace = emqx_dashboard:get_namespace(Req),
    handle_node_operation(Namespace, ?ROOT_KEY_SOURCES, Node, Id, Op).

'/sources_probe'(post, Request) ->
    Namespace = emqx_dashboard:get_namespace(Request),
    handle_probe(Namespace, ?ROOT_KEY_SOURCES, Request).

'/sources_summary'(get, Request) ->
    Namespace = emqx_dashboard:get_namespace(Request),
    handle_summary(Namespace, ?ROOT_KEY_SOURCES).

'/source_types'(get, _Request) ->
    ?OK(emqx_bridge_v2_schema:source_types()).

%%------------------------------------------------------------------------------
%% Handlers
%%------------------------------------------------------------------------------

handle_list(Namespace, ConfRootKey) ->
    Nodes = nodes_supporting_bpapi_version(8),
    NodeReplies = emqx_bridge_proto_v8:list(Nodes, Namespace, ConfRootKey),
    case is_ok(NodeReplies) of
        {ok, NodeBridges} ->
            AllBridges = [
                [format_resource(ConfRootKey, Data, Node) || Data <- Bridges]
             || {Node, Bridges} <- lists:zip(Nodes, NodeBridges)
            ],
            ?OK(zip_bridges(Namespace, ConfRootKey, AllBridges));
        {error, Reason} ->
            ?INTERNAL_ERROR(Reason)
    end.

handle_summary(Namespace, ConfRootKey) ->
    case do_handle_summary(Namespace, ConfRootKey) of
        {ok, ZippedBridges} ->
            ?OK(ZippedBridges);
        {error, Reason} ->
            ?INTERNAL_ERROR(Reason)
    end.

do_handle_summary(Namespace, ConfRootKey) ->
    Nodes = nodes_supporting_bpapi_version(8),
    NodeReplies = emqx_bridge_proto_v8:summary(Nodes, Namespace, ConfRootKey),
    maybe
        {ok, AllBridges} ?= is_ok(NodeReplies),
        ZippedBridges = zip_bridges(Namespace, ConfRootKey, AllBridges),
        {ok, add_fallback_actions_references(Namespace, ConfRootKey, ZippedBridges)}
    end.

handle_create(Namespace, ConfRootKey, Type, Name, Conf0) ->
    case emqx_bridge_v2:is_exist(Namespace, ConfRootKey, Type, Name) of
        true ->
            ?BAD_REQUEST('ALREADY_EXISTS', <<"bridge already exists">>);
        false ->
            Conf = filter_out_request_body(Conf0),
            create_bridge(Namespace, ConfRootKey, Type, Name, Conf)
    end.

handle_update(Namespace, ConfRootKey, Id, Conf0) ->
    Conf1 = filter_out_request_body(Conf0),
    ?TRY_PARSE_ID(
        Id,
        case emqx_bridge_v2:is_exist(Namespace, ConfRootKey, BridgeType, BridgeName) of
            true ->
                RawConf = get_raw_config(Namespace, [ConfRootKey, BridgeType, BridgeName], #{}),
                Conf = emqx_utils:deobfuscate(Conf1, RawConf),
                update_bridge(Namespace, ConfRootKey, BridgeType, BridgeName, Conf);
            false ->
                ?BRIDGE_NOT_FOUND(BridgeType, BridgeName)
        end
    ).

handle_delete(Namespace, ConfRootKey, Id, QueryStringOpts) ->
    ?TRY_PARSE_ID(
        Id,
        case emqx_bridge_v2:is_exist(Namespace, ConfRootKey, BridgeType, BridgeName) of
            true ->
                AlsoDeleteActions =
                    case maps:get(<<"also_delete_dep_actions">>, QueryStringOpts, <<"false">>) of
                        <<"true">> -> true;
                        true -> true;
                        _ -> false
                    end,
                case
                    emqx_bridge_v2:check_deps_and_remove(
                        Namespace, ConfRootKey, BridgeType, BridgeName, AlsoDeleteActions
                    )
                of
                    ok ->
                        ?NO_CONTENT;
                    {error, #{
                        reason := rules_depending_on_this_bridge,
                        rule_ids := RuleIds
                    }} ->
                        Msg0 = ?ERROR_MSG(
                            'BAD_REQUEST',
                            bin("Cannot delete action while active rules are depending on it")
                        ),
                        Msg = Msg0#{rules => RuleIds},
                        {400, Msg};
                    {error, timeout} ->
                        ?SERVICE_UNAVAILABLE(<<"request timeout">>);
                    {error, Reason} ->
                        ?INTERNAL_ERROR(Reason)
                end;
            false ->
                ?BRIDGE_NOT_FOUND(BridgeType, BridgeName)
        end
    ).

handle_reset_metrics(Namespace, ConfRootKey, Id) ->
    ?TRY_PARSE_ID(
        Id,
        begin
            ActionType = emqx_bridge_v2:bridge_v2_type_to_connector_type(BridgeType),
            ok = emqx_bridge_v2:reset_metrics(Namespace, ConfRootKey, ActionType, BridgeName),
            ?NO_CONTENT
        end
    ).

handle_disable_enable(Namespace, ConfRootKey, Id, Enable) ->
    ?TRY_PARSE_ID(
        Id,
        case
            emqx_bridge_v2:disable_enable(
                Namespace, ConfRootKey, enable_func(Enable), BridgeType, BridgeName
            )
        of
            {ok, _} ->
                wait_for_ready(Namespace, ConfRootKey, BridgeType, BridgeName),
                ?NO_CONTENT;
            {error, {pre_config_update, _, bridge_not_found}} ->
                ?BRIDGE_NOT_FOUND(BridgeType, BridgeName);
            {error, {_, _, timeout}} ->
                ?SERVICE_UNAVAILABLE(<<"request timeout">>);
            {error, timeout} ->
                ?SERVICE_UNAVAILABLE(<<"request timeout">>);
            {error, Reason} when is_binary(Reason) ->
                ?BAD_REQUEST(Reason);
            {error, Reason} ->
                ?INTERNAL_ERROR(Reason)
        end
    ).

handle_operation(Namespace, ConfRootKey, Id, Op) ->
    ?TRY_PARSE_ID(
        Id,
        begin
            {ProtoMod, OperFunc} = operation_func(Op),
            Nodes = nodes_supporting_bpapi_version(8),
            BPAPIArgs = [Nodes, Namespace, ConfRootKey, BridgeType, BridgeName],
            call_operation_if_enabled(
                ProtoMod, OperFunc, Namespace, ConfRootKey, BridgeType, BridgeName, BPAPIArgs
            )
        end
    ).

handle_node_operation(Namespace, ConfRootKey, Node, Id, Op) ->
    ?TRY_PARSE_ID(
        Id,
        case emqx_utils:safe_to_existing_atom(Node, utf8) of
            {ok, TargetNode} ->
                {ProtoMod, OperFunc} = operation_func(Op),
                BPAPIArgs = [[TargetNode], Namespace, ConfRootKey, BridgeType, BridgeName],
                call_operation_if_enabled(
                    ProtoMod, OperFunc, Namespace, ConfRootKey, BridgeType, BridgeName, BPAPIArgs
                );
            {error, _} ->
                ?NOT_FOUND(<<"Invalid node name: ", Node/binary>>)
        end
    ).

handle_probe(Namespace, ConfRootKey, Request) ->
    Path =
        case ConfRootKey of
            ?ROOT_KEY_ACTIONS -> "/actions_probe";
            ?ROOT_KEY_SOURCES -> "/sources_probe"
        end,
    RequestMeta = #{module => ?MODULE, method => post, path => Path},
    case emqx_dashboard_swagger:filter_check_request_and_translate_body(Request, RequestMeta) of
        {ok, #{body := #{<<"type">> := Type} = Params}} ->
            Params1 = maybe_deobfuscate_bridge_probe(Namespace, ConfRootKey, Params),
            Params2 = maps:remove(<<"type">>, Params1),
            case emqx_bridge_v2:create_dry_run(Namespace, ConfRootKey, Type, Params2) of
                ok ->
                    ?NO_CONTENT;
                {error, #{kind := validation_error} = Reason0} ->
                    Reason = redact(Reason0),
                    ?BAD_REQUEST('TEST_FAILED', emqx_mgmt_api_lib:to_json(Reason));
                {error, Reason0} when not is_tuple(Reason0); element(1, Reason0) =/= 'exit' ->
                    Reason1 =
                        case Reason0 of
                            {unhealthy_target, Message} -> Message;
                            _ -> Reason0
                        end,
                    Reason = redact(Reason1),
                    ?BAD_REQUEST('TEST_FAILED', Reason)
            end;
        BadRequest ->
            redact(BadRequest)
    end.

%%% API helpers
maybe_deobfuscate_bridge_probe(
    Namespace,
    ConfRootKey,
    #{<<"type">> := ActionType, <<"name">> := BridgeName} = Params
) ->
    case emqx_bridge_v2:lookup_raw_conf(Namespace, ConfRootKey, ActionType, BridgeName) of
        {ok, RawConf} ->
            emqx_utils:deobfuscate(Params, RawConf);
        _ ->
            %% A bridge may be probed before it's created, so not finding it here is fine
            Params
    end;
maybe_deobfuscate_bridge_probe(_Namespace, _ConfRootKey, Params) ->
    Params.

is_ok(ok) ->
    ok;
is_ok(OkResult = {ok, _}) ->
    OkResult;
is_ok(Error = {error, _}) ->
    Error;
is_ok(ResL) ->
    case
        lists:filter(
            fun
                ({ok, _}) -> false;
                (ok) -> false;
                (_) -> true
            end,
            ResL
        )
    of
        [] -> {ok, [Res || {ok, Res} <- ResL]};
        ErrL -> hd(ErrL)
    end.

%% bridge helpers
-spec lookup_from_all_nodes(maybe_namespace(), emqx_bridge_v2:root_cfg_key(), _, _, _) -> _.
lookup_from_all_nodes(Namespace, ConfRootKey, BridgeType, BridgeName, SuccCode) ->
    Nodes = nodes_supporting_bpapi_version(8),
    case
        is_ok(
            emqx_bridge_proto_v8:lookup(
                Nodes, Namespace, ConfRootKey, BridgeType, BridgeName
            )
        )
    of
        {ok, [{ok, _} | _] = Results0} ->
            Results = [R || {ok, R} <- Results0],
            {SuccCode, format_bridge_info(Namespace, ConfRootKey, BridgeType, BridgeName, Results)};
        {ok, [{error, not_found} | _]} ->
            ?BRIDGE_NOT_FOUND(BridgeType, BridgeName);
        {error, Reason} ->
            ?INTERNAL_ERROR(Reason)
    end.

get_metrics_from_all_nodes(Namespace, ConfRootKey, Type, Name) ->
    Nodes = nodes_supporting_bpapi_version(8),
    Result = maybe_unwrap(
        emqx_bridge_proto_v8:get_metrics(Nodes, Namespace, ConfRootKey, Type, Name)
    ),
    case Result of
        Metrics when is_list(Metrics) ->
            {200, format_bridge_metrics(lists:zip(Nodes, Metrics))};
        {error, Reason} ->
            ?INTERNAL_ERROR(Reason)
    end.

operation_func(start) ->
    {emqx_bridge_proto_v8, start}.

call_operation_if_enabled(ProtoMod, OperFunc, Namespace, ConfRootKey, Type, Name, BPAPIArgs) ->
    try is_enabled_bridge(Namespace, ConfRootKey, Type, Name) of
        false ->
            ?BAD_REQUEST(<<"Forbidden operation, connector not enabled">>);
        true ->
            call_operation(ProtoMod, OperFunc, Namespace, ConfRootKey, Type, Name, BPAPIArgs)
    catch
        throw:not_found ->
            ?BRIDGE_NOT_FOUND(Type, Name)
    end.

is_enabled_bridge(Namespace, ConfRootKey, ActionOrSourceType, BridgeName) ->
    try
        emqx_bridge_v2:lookup(
            Namespace, ConfRootKey, ActionOrSourceType, binary_to_existing_atom(BridgeName)
        )
    of
        {ok, #{raw_config := ConfMap}} ->
            maps:get(<<"enable">>, ConfMap, true) andalso
                is_connector_enabled(
                    Namespace,
                    ActionOrSourceType,
                    maps:get(<<"connector">>, ConfMap)
                );
        {error, not_found} ->
            throw(not_found)
    catch
        error:badarg ->
            %% catch non-existing atom,
            %% none-existing atom means it is not available in config PT storage.
            throw(not_found);
        error:{badkey, _} ->
            %% `connector' field not present.  Should never happen if action/source schema
            %% is properly defined.
            throw(not_found)
    end.

is_connector_enabled(Namespace, ActionOrSourceType, ConnectorName0) ->
    try
        ConnectorType = emqx_bridge_v2:connector_type(ActionOrSourceType),
        ConnectorName = to_existing_atom(ConnectorName0),
        case get_config(Namespace, [connectors, ConnectorType, ConnectorName], undefined) of
            undefined ->
                throw(not_found);
            Config = #{} ->
                maps:get(enable, Config, true)
        end
    catch
        throw:badarg ->
            %% catch non-existing atom,
            %% none-existing atom means it is not available in config PT storage.
            throw(not_found);
        throw:bad_atom ->
            %% catch non-existing atom,
            %% none-existing atom means it is not available in config PT storage.
            throw(not_found)
    end.

call_operation(ProtoMod, OperFunc, Namespace, ConfRootKey, Type, Name, BPAPIArgs) ->
    case is_ok(do_bpapi_call(ProtoMod, OperFunc, BPAPIArgs)) of
        Ok when Ok =:= ok; is_tuple(Ok), element(1, Ok) =:= ok ->
            ?NO_CONTENT;
        {error, not_implemented} ->
            ?NOT_IMPLEMENTED;
        {error, timeout} ->
            BridgeId = emqx_bridge_resource:bridge_id(Type, Name),
            ?SLOG(warning, #{
                msg => "bridge_bpapi_call_timeout",
                namespace => Namespace,
                kind => ConfRootKey,
                bridge => BridgeId,
                call => OperFunc
            }),
            ?SERVICE_UNAVAILABLE(<<"Request timeout">>);
        {error, {start_pool_failed, Name1, Reason}} ->
            Msg = bin(
                io_lib:format("Failed to start ~p pool for reason ~p", [Name1, redact(Reason)])
            ),
            ?BAD_REQUEST(Msg);
        {error, not_found} ->
            BridgeId = emqx_bridge_resource:bridge_id(Type, Name),
            ?SLOG(warning, #{
                msg => "bridge_inconsistent_in_cluster_for_call_operation",
                reason => not_found,
                namespace => Namespace,
                kind => ConfRootKey,
                bridge => BridgeId,
                call => OperFunc
            }),
            ?SERVICE_UNAVAILABLE(<<"Bridge not found on remote node: ", BridgeId/binary>>);
        {error, {node_not_found, Node}} ->
            ?NOT_FOUND(<<"Node not found: ", (atom_to_binary(Node))/binary>>);
        {error, Reason} ->
            ?BAD_REQUEST(redact(Reason))
    end.

do_bpapi_call(ProtoMod, OperFunc, Args) ->
    maybe_unwrap(apply(ProtoMod, OperFunc, Args)).

nodes_supporting_bpapi_version(Vsn) ->
    emqx_bpapi:nodes_supporting_bpapi_version(?BPAPI_NAME, Vsn).

maybe_unwrap(RpcMulticallResult) ->
    emqx_rpc:unwrap_erpc(RpcMulticallResult).

%% Note: this must be called on the local node handling the request, not during RPCs.
zip_bridges(Namespace, ConfRootKey, [BridgesFirstNode | _] = BridgesAllNodes) ->
    %% TODO: make this a `lists:map`...
    lists:foldl(
        fun(#{type := Type, name := Name}, Acc) ->
            Bridges = pick_bridges_by_id(Type, Name, BridgesAllNodes),
            [format_bridge_info(Namespace, ConfRootKey, Type, Name, Bridges) | Acc]
        end,
        [],
        BridgesFirstNode
    ).

%% This works on the output of `zip_bridges`.
add_fallback_actions_references(Namespace, ?ROOT_KEY_ACTIONS = ConfRootKey, ZippedBridges) ->
    Conf = get_config(Namespace, [ConfRootKey], #{}),
    case Conf of
        #{?COMPUTED := #{fallback_actions_index := Index}} ->
            lists:map(
                fun(#{type := ReferencedType, name := ReferencedName} = Info) ->
                    Referencing0 = maps:get(
                        {bin(ReferencedType), bin(ReferencedName)},
                        Index,
                        []
                    ),
                    Referencing = lists:map(fun(R) -> maps:with([type, name], R) end, Referencing0),
                    Info#{referenced_as_fallback_action_by => Referencing}
                end,
                ZippedBridges
            );
        #{} ->
            %% Namespaced config not initialized properly?
            lists:map(
                fun(Info) -> Info#{referenced_as_fallback_action_by => []} end,
                ZippedBridges
            )
    end;
add_fallback_actions_references(_Namespace, ?ROOT_KEY_SOURCES, ZippedBridges) ->
    ZippedBridges.

pick_bridges_by_id(Type, Name, BridgesAllNodes) ->
    lists:foldl(
        fun(BridgesOneNode, Acc) ->
            case
                [
                    Bridge
                 || Bridge = #{type := Type0, name := Name0} <- BridgesOneNode,
                    Type0 == Type,
                    Name0 == Name
                ]
            of
                [BridgeInfo] ->
                    [BridgeInfo | Acc];
                [] ->
                    ?SLOG(warning, #{
                        msg => "bridge_inconsistent_in_cluster",
                        reason => not_found,
                        type => Type,
                        name => Name,
                        bridge => emqx_bridge_resource:bridge_id(Type, Name)
                    }),
                    Acc
            end
        end,
        [],
        BridgesAllNodes
    ).

%% Note: this must be called on the local node handling the request, not during RPCs.
format_bridge_info(Namespace, ConfRootKey, Type, Name, [FirstBridge | _] = Bridges) ->
    Res0 = maps:remove(node, FirstBridge),
    NodeStatus = node_status(Bridges),
    Id = emqx_bridge_resource:bridge_id(Type, Name),
    Rules =
        case ConfRootKey of
            actions -> emqx_rule_engine:get_rule_ids_by_bridge_action(Namespace, Id);
            sources -> emqx_rule_engine:get_rule_ids_by_bridge_source(Namespace, Id)
        end,
    Res1 = Res0#{
        status => aggregate_status(NodeStatus),
        node_status => NodeStatus,
        rules => lists:sort(Rules)
    },
    Res2 = enrich_fallback_actions_info(Namespace, Res1),
    redact(Res2).

node_status(Bridges) ->
    [maps:with([node, status, status_reason], B) || B <- Bridges].

aggregate_status(AllStatus) ->
    Head = fun([A | _]) -> A end,
    HeadVal = maps:get(status, Head(AllStatus), connecting),
    AllRes = lists:all(
        fun
            (#{status := Val}) -> Val == HeadVal;
            (_) -> false
        end,
        AllStatus
    ),
    case AllRes of
        true -> HeadVal;
        false -> inconsistent
    end.

%% RPC Target
lookup_from_local_node(Type, Name) ->
    lookup_v8(?global_ns, ?ROOT_KEY_ACTIONS, Type, Name).

%% RPC Target
-spec lookup_from_local_node_v6(emqx_bridge_v2:root_cfg_key(), _, _) -> _.
lookup_from_local_node_v6(ConfRootKey, Type, Name) ->
    lookup_v8(?global_ns, ConfRootKey, Type, Name).

%% RPC Target
-spec lookup_v8(maybe_namespace(), emqx_bridge_v2:root_cfg_key(), _, _) -> _.
lookup_v8(Namespace, ConfRootKey, Type, Name) ->
    case emqx_bridge_v2:lookup(Namespace, ConfRootKey, Type, Name) of
        {ok, Res} -> {ok, format_resource(ConfRootKey, Res, node())};
        Error -> Error
    end.

%% RPC Target
get_metrics_from_local_node(ActionType, ActionName) ->
    get_metrics_v8(?global_ns, ?ROOT_KEY_ACTIONS, ActionType, ActionName).

%% RPC Target
get_metrics_from_local_node_v6(ConfRootKey, Type, Name) ->
    get_metrics_v8(?global_ns, ConfRootKey, Type, Name).

%% RPC Target
get_metrics_v8(Namespace, ConfRootKey, Type, Name) ->
    format_metrics(emqx_bridge_v2:get_metrics(Namespace, ConfRootKey, Type, Name)).

%% RPC Target
summary_from_local_node_v7(ConfRootKey) ->
    summary_v8(?global_ns, ConfRootKey).

%% RPC Target
summary_v8(Namespace, ConfRootKey) ->
    lists:map(
        fun(BridgeInfo) ->
            #{
                type := Type,
                name := Name,
                status := Status,
                error := Error,
                raw_config := RawConfig
            } = BridgeInfo,
            CreatedAt = maps:get(<<"created_at">>, RawConfig, undefined),
            LastModifiedAt = maps:get(<<"last_modified_at">>, RawConfig, undefined),
            Description = maps:get(<<"description">>, RawConfig, <<"">>),
            Tags = maps:get(<<"tags">>, RawConfig, []),
            IsEnabled = maps:get(<<"enable">>, RawConfig, true),
            maps:merge(
                #{
                    node => node(),
                    type => Type,
                    name => Name,
                    description => Description,
                    tags => Tags,
                    enable => IsEnabled,
                    created_at => CreatedAt,
                    last_modified_at => LastModifiedAt
                },
                format_bridge_status_and_error(#{status => Status, error => Error})
            )
        end,
        emqx_bridge_v2:list(Namespace, ConfRootKey)
    ).

wait_for_ready(Namespace, ConfRootKey, Type, Name) ->
    Nodes = nodes_supporting_bpapi_version(8),
    CallsTimeout = 2 * 5_000,
    RPCTimeout = CallsTimeout + 1_000,
    _ = emqx_bridge_proto_v8:wait_for_ready(
        Nodes,
        Namespace,
        ConfRootKey,
        Type,
        Name,
        RPCTimeout
    ),
    ok.

%% RPC Target
wait_for_ready_local_node_v7(ConfRootKey, Type, Name) ->
    wait_for_ready_v8(?global_ns, ConfRootKey, Type, Name).

%% RPC Target
wait_for_ready_v8(Namespace, ConfRootKey, Type, Name) ->
    try
        {ok, {ConnResId, ChannelResId}} =
            emqx_bridge_v2:get_resource_ids(Namespace, ConfRootKey, Type, Name),
        emqx_resource_manager:channel_health_check(ConnResId, ChannelResId)
    catch
        exit:{timeout, _} ->
            {error, timeout}
    end.

%% resource
format_resource(
    ConfRootKey,
    #{
        type := Type,
        name := Name,
        status := Status,
        error := Error,
        raw_config := RawConf0,
        resource_data := _ResourceData
    },
    Node
) ->
    RawConf = fill_defaults(ConfRootKey, Type, RawConf0),
    redact(
        maps:merge(
            RawConf#{
                type => Type,
                name => maps:get(<<"name">>, RawConf, Name),
                node => Node,
                status => Status,
                error => Error
            },
            format_bridge_status_and_error(#{status => Status, error => Error})
        )
    ).

%% FIXME:
%% missing metrics:
%% 'retried.success' and 'retried.failed'
format_metrics(#{
    counters := #{
        'dropped' := Dropped,
        'dropped.other' := DroppedOther,
        'dropped.expired' := DroppedExpired,
        'dropped.queue_full' := DroppedQueueFull,
        'dropped.resource_not_found' := DroppedResourceNotFound,
        'dropped.resource_stopped' := DroppedResourceStopped,
        'matched' := Matched,
        'retried' := Retried,
        'late_reply' := LateReply,
        'failed' := SentFailed,
        'success' := SentSucc,
        'received' := Rcvd
    },
    gauges := Gauges,
    rate := #{
        matched := #{current := Rate, last5m := Rate5m, max := RateMax}
    }
}) ->
    Queued = maps:get('queuing', Gauges, 0),
    QueuedBytes = maps:get('queuing_bytes', Gauges, 0),
    SentInflight = maps:get('inflight', Gauges, 0),
    ?METRICS(
        Dropped,
        DroppedOther,
        DroppedExpired,
        DroppedQueueFull,
        DroppedResourceNotFound,
        DroppedResourceStopped,
        Matched,
        Queued,
        QueuedBytes,
        Retried,
        LateReply,
        SentFailed,
        SentInflight,
        SentSucc,
        Rate,
        Rate5m,
        RateMax,
        Rcvd
    );
format_metrics(_Metrics) ->
    %% Empty metrics: can happen when a node joins another and a
    %% bridge is not yet replicated to it, so the counters map is
    %% empty.
    empty_metrics().

empty_metrics() ->
    ?METRICS(
        _Dropped = 0,
        _DroppedOther = 0,
        _DroppedExpired = 0,
        _DroppedQueueFull = 0,
        _DroppedResourceNotFound = 0,
        _DroppedResourceStopped = 0,
        _Matched = 0,
        _Queued = 0,
        _QueuedBytes = 0,
        _Retried = 0,
        _LateReply = 0,
        _SentFailed = 0,
        _SentInflight = 0,
        _SentSucc = 0,
        _Rate = 0,
        _Rate5m = 0,
        _RateMax = 0,
        _Rcvd = 0
    ).

format_bridge_metrics(Bridges) ->
    NodeMetrics = lists:filtermap(
        fun
            ({Node, Metrics}) when is_map(Metrics) ->
                {true, #{node => Node, metrics => Metrics}};
            ({Node, _}) ->
                {true, #{node => Node, metrics => empty_metrics()}}
        end,
        Bridges
    ),
    #{
        metrics => aggregate_metrics(NodeMetrics),
        node_metrics => NodeMetrics
    }.

aggregate_metrics(AllMetrics) ->
    InitMetrics = ?EMPTY_METRICS,
    lists:foldl(fun aggregate_metrics/2, InitMetrics, AllMetrics).

aggregate_metrics(
    #{
        metrics := ?metrics(
            M1, M2, M3, M4, M5, M6, M7, M8, M9, M10, M11, M12, M13, M14, M15, M16, M17, M18
        )
    },
    ?metrics(
        N1, N2, N3, N4, N5, N6, N7, N8, N9, N10, N11, N12, N13, N14, N15, N16, N17, N18
    )
) ->
    ?METRICS(
        M1 + N1,
        M2 + N2,
        M3 + N3,
        M4 + N4,
        M5 + N5,
        M6 + N6,
        M7 + N7,
        M8 + N8,
        M9 + N9,
        M10 + N10,
        M11 + N11,
        M12 + N12,
        M13 + N13,
        M14 + N14,
        M15 + N15,
        M16 + N16,
        M17 + N17,
        M18 + N18
    ).

%% Called locally, not during RPC.
enrich_fallback_actions_info(Namespace, Info) ->
    emqx_utils_maps:update_if_present(
        <<"fallback_actions">>,
        fun(FBAs0) ->
            lists:map(
                fun
                    (#{<<"kind">> := <<"reference">>, <<"type">> := T, <<"name">> := N} = FBA) ->
                        Tags = get_raw_config(Namespace, [<<"actions">>, T, N, <<"tags">>], []),
                        FBA#{<<"tags">> => Tags};
                    (A) ->
                        %% Republish
                        A
                end,
                FBAs0
            )
        end,
        Info
    ).

fill_defaults(ConfRootKey, Type, RawConf) ->
    PackedConf = pack_bridge_conf(ConfRootKey, Type, RawConf),
    FullConf = emqx_config:fill_defaults(emqx_bridge_v2_schema, PackedConf, #{}),
    unpack_bridge_conf(ConfRootKey, Type, FullConf).

pack_bridge_conf(ConfRootKey, Type, RawConf) ->
    #{bin(ConfRootKey) => #{bin(Type) => #{<<"foo">> => RawConf}}}.

unpack_bridge_conf(ConfRootKey, Type, PackedConf) ->
    ConfRootKeyBin = bin(ConfRootKey),
    TypeBin = bin(Type),
    #{ConfRootKeyBin := Bridges} = PackedConf,
    #{<<"foo">> := RawConf} = maps:get(TypeBin, Bridges),
    RawConf.

format_bridge_status_and_error(Data) ->
    maps:fold(fun format_resource_data/3, #{}, maps:with([status, error], Data)).

format_resource_data(error, undefined, Result) ->
    Result;
format_resource_data(error, Error, Result) ->
    Result#{status_reason => emqx_utils:readable_error_msg(Error)};
format_resource_data(K, V, Result) ->
    Result#{K => V}.

create_bridge(Namespace, ConfRootKey, BridgeType, BridgeName, Conf) ->
    create_or_update_bridge(Namespace, ConfRootKey, BridgeType, BridgeName, Conf, 201).

update_bridge(Namespace, ConfRootKey, BridgeType, BridgeName, Conf) ->
    create_or_update_bridge(Namespace, ConfRootKey, BridgeType, BridgeName, Conf, 200).

create_or_update_bridge(Namespace, ConfRootKey, BridgeType, BridgeName, Conf, HttpStatusCode) ->
    Check =
        try
            is_binary(BridgeType) andalso emqx_resource:validate_type(BridgeType),
            ok = emqx_resource:validate_name(BridgeName)
        catch
            throw:Error ->
                ?BAD_REQUEST(emqx_mgmt_api_lib:to_json(Error))
        end,
    maybe
        ok ?= Check,
        do_create_or_update_bridge(
            Namespace, ConfRootKey, BridgeType, BridgeName, Conf, HttpStatusCode
        )
    end.

do_create_or_update_bridge(Namespace, ConfRootKey, BridgeType, BridgeName, Conf, HttpStatusCode) ->
    case emqx_bridge_v2:create(Namespace, ConfRootKey, BridgeType, BridgeName, Conf) of
        {ok, _} ->
            wait_for_ready(Namespace, ConfRootKey, BridgeType, BridgeName),
            lookup_from_all_nodes(Namespace, ConfRootKey, BridgeType, BridgeName, HttpStatusCode);
        {error, {PreOrPostConfigUpdate, _HandlerMod, Reason}} when
            PreOrPostConfigUpdate =:= pre_config_update;
            PreOrPostConfigUpdate =:= post_config_update
        ->
            ?BAD_REQUEST(emqx_mgmt_api_lib:to_json(redact(Reason)));
        {error, Reason} when is_binary(Reason) ->
            ?BAD_REQUEST(Reason);
        {error, #{error := uninstall_timeout} = Reason} ->
            ?SERVICE_UNAVAILABLE(emqx_mgmt_api_lib:to_json(redact(Reason)));
        {error, Reason} when is_map(Reason) ->
            ?BAD_REQUEST(emqx_mgmt_api_lib:to_json(redact(Reason)))
    end.

enable_func(true) -> enable;
enable_func(false) -> disable.

filter_out_request_body(Conf) ->
    ExtraConfs = [
        <<"id">>,
        <<"type">>,
        <<"name">>,
        <<"status">>,
        <<"status_reason">>,
        <<"node_status">>,
        <<"node">>
    ],
    maps:without(ExtraConfs, Conf).

%% general helpers
bin(S) when is_list(S) ->
    list_to_binary(S);
bin(S) when is_atom(S) ->
    atom_to_binary(S, utf8);
bin(S) when is_binary(S) ->
    S.

to_existing_atom(X) ->
    case emqx_utils:safe_to_existing_atom(X, utf8) of
        {ok, A} -> A;
        {error, _} -> throw(bad_atom)
    end.

get_config(Namespace, KeyPath, Default) when is_binary(Namespace) ->
    emqx:get_namespaced_config(Namespace, KeyPath, Default);
get_config(?global_ns, KeyPath, Default) ->
    emqx:get_config(KeyPath, Default).

get_raw_config(Namespace, KeyPath, Default) when is_binary(Namespace) ->
    emqx:get_raw_namespaced_config(Namespace, KeyPath, Default);
get_raw_config(?global_ns, KeyPath, Default) ->
    emqx:get_raw_config(KeyPath, Default).
