%%--------------------------------------------------------------------
%% Copyright (c) 2023-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bridge_es).

-include("emqx_bridge_es.hrl").
-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").

-export([bridge_v2_examples/1]).

%% hocon_schema API
-export([namespace/0, roots/0, fields/1, desc/1]).

-define(CONNECTOR_TYPE, elasticsearch).
-define(ACTION_TYPE, ?CONNECTOR_TYPE).

namespace() -> "bridge_elasticsearch".

roots() -> [].

fields(action) ->
    {elasticsearch,
        ?HOCON(
            ?MAP(action_name, ?R_REF(action_config)),
            #{
                required => false,
                desc => ?DESC(elasticsearch)
            }
        )};
fields(action_config) ->
    emqx_bridge_v2_schema:make_producer_action_schema(
        ?HOCON(
            ?UNION(fun action_union_member_selector/1),
            #{
                required => true, desc => ?DESC("action_parameters")
            }
        ),
        #{resource_opts_ref => ?R_REF(action_resource_opts)}
    );
fields(action_resource_opts) ->
    lists:filter(
        fun({K, _V}) ->
            not lists:member(K, unsupported_opts())
        end,
        emqx_bridge_v2_schema:action_resource_opts_fields()
    );
fields(action_create) ->
    [
        action_field(create, ?DESC(create)),
        index(),
        id(false),
        doc(),
        routing(),
        require_alias(),
        overwrite()
        | http_common_opts()
    ];
fields(action_delete) ->
    [action_field(delete, ?DESC(delete)), index(), id(true), routing() | http_common_opts()];
fields(action_update) ->
    [
        action_field(update, ?DESC(update)),
        index(),
        id(true),
        doc(),
        doc_as_upsert(),
        routing(),
        require_alias()
        | http_common_opts()
    ];
fields(Field) when
    Field == "get_bridge_v2";
    Field == "put_bridge_v2";
    Field == "post_bridge_v2"
->
    emqx_bridge_v2_schema:api_fields(Field, ?ACTION_TYPE, fields(action_config)).

action_union_member_selector(all_union_members) ->
    [
        ?R_REF(action_create),
        ?R_REF(action_delete),
        ?R_REF(action_update)
    ];
action_union_member_selector({value, Value}) ->
    case Value of
        #{<<"action">> := <<"create">>} ->
            [?R_REF(action_create)];
        #{<<"action">> := <<"delete">>} ->
            [?R_REF(action_delete)];
        #{<<"action">> := <<"update">>} ->
            [?R_REF(action_update)];
        #{<<"action">> := Action} when is_atom(Action) ->
            Value1 = Value#{<<"action">> => atom_to_binary(Action)},
            action_union_member_selector({value, Value1});
        Actual ->
            Expected = "create | delete | update",
            throw(#{
                field_name => action,
                actual => Actual,
                expected => Expected
            })
    end.

action_field(Action, Desc) ->
    {action,
        ?HOCON(
            Action,
            #{
                required => true,
                desc => Desc
            }
        )}.

overwrite() ->
    {overwrite,
        ?HOCON(
            boolean(),
            #{
                required => false,
                default => true,
                desc => ?DESC("config_overwrite")
            }
        )}.

index() ->
    {index,
        ?HOCON(
            emqx_schema:template(),
            #{
                required => true,
                example => <<"${payload.index}">>,
                desc => ?DESC("config_parameters_index")
            }
        )}.

id(Required) ->
    {id,
        ?HOCON(
            emqx_schema:template(),
            #{
                required => Required,
                example => <<"${payload.id}">>,
                desc => ?DESC("config_parameters_id")
            }
        )}.

doc() ->
    {doc,
        ?HOCON(
            emqx_schema:template(),
            #{
                required => false,
                example => <<"${payload.doc}">>,
                desc => ?DESC("config_parameters_doc")
            }
        )}.

http_common_opts() ->
    lists:filter(
        fun({K, _}) ->
            not lists:member(K, [path, method, body, headers, request_timeout])
        end,
        emqx_bridge_http_schema:fields("parameters_opts")
    ).

doc_as_upsert() ->
    {doc_as_upsert,
        ?HOCON(
            boolean(),
            #{
                required => false,
                default => false,
                desc => ?DESC("config_doc_as_upsert")
            }
        )}.

routing() ->
    {routing,
        ?HOCON(
            emqx_schema:template(),
            #{
                required => false,
                example => <<"${payload.routing}">>,
                desc => ?DESC("config_routing")
            }
        )}.

require_alias() ->
    {require_alias,
        ?HOCON(
            boolean(),
            #{
                required => false,
                desc => ?DESC("config_require_alias")
            }
        )}.

bridge_v2_examples(Method) ->
    [
        #{
            <<"elasticsearch">> =>
                #{
                    summary => <<"Elastic Search Bridge">>,
                    value => emqx_bridge_v2_schema:action_values(
                        Method, ?ACTION_TYPE, ?CONNECTOR_TYPE, action_values()
                    )
                }
        }
    ].

action_values() ->
    #{
        parameters => #{
            action => create,
            index => <<"${payload.index}">>,
            overwrite => true,
            doc => <<"${payload.doc}">>
        }
    }.

unsupported_opts() ->
    [
        batch_size,
        batch_time
    ].

desc(elasticsearch) -> ?DESC(elasticsearch);
desc(action_config) -> ?DESC(action_config);
desc(action_create) -> ?DESC(action_create);
desc(action_delete) -> ?DESC(action_delete);
desc(action_update) -> ?DESC(action_update);
desc(action_resource_opts) -> ?DESC(action_resource_opts);
desc(_) -> undefined.
