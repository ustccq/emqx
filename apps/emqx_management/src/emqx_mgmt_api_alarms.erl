%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_mgmt_api_alarms).

-behaviour(minirest_api).

-include_lib("hocon/include/hoconsc.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("typerefl/include/types.hrl").

-export([api_spec/0, paths/0, schema/1, fields/1, namespace/0]).

-export([alarms/2, format_alarm/2]).

-define(TAGS, [<<"Alarms">>]).

%% internal export (for query)
-export([qs2ms/2]).

namespace() ->
    undefined.

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true}).

paths() ->
    ["/alarms"].

schema("/alarms") ->
    #{
        'operationId' => alarms,
        get => #{
            description => ?DESC(list_alarms_api),
            tags => ?TAGS,
            parameters => [
                hoconsc:ref(emqx_dashboard_swagger, page),
                hoconsc:ref(emqx_dashboard_swagger, limit),
                {activated,
                    hoconsc:mk(boolean(), #{
                        in => query,
                        desc => ?DESC(get_alarms_qs_activated),
                        required => false
                    })}
            ],
            responses => #{
                200 => [
                    {data, hoconsc:mk(hoconsc:array(hoconsc:ref(?MODULE, alarm)), #{})},
                    {meta, hoconsc:mk(hoconsc:ref(emqx_dashboard_swagger, meta), #{})}
                ]
            }
        },
        delete => #{
            description => ?DESC(delete_alarms_api),
            tags => ?TAGS,
            responses => #{
                204 => ?DESC(delete_alarms_api_response204)
            }
        }
    }.

fields(alarm) ->
    [
        {node,
            hoconsc:mk(
                binary(),
                #{desc => ?DESC(node), example => atom_to_list(node())}
            )},
        {name,
            hoconsc:mk(
                binary(),
                #{desc => ?DESC(node), example => <<"high_system_memory_usage">>}
            )},
        {message,
            hoconsc:mk(binary(), #{
                desc => ?DESC(message),
                example => <<"System memory usage is higher than 70%">>
            })},
        {details,
            hoconsc:mk(map(), #{
                desc => ?DESC(details),
                example => #{<<"high_watermark">> => 70}
            })},
        {duration, hoconsc:mk(integer(), #{desc => ?DESC(duration), example => 297056})},
        {activate_at,
            hoconsc:mk(binary(), #{
                desc => ?DESC(activate_at),
                example => <<"2021-10-25T11:52:52.548+08:00">>
            })},
        {deactivate_at,
            hoconsc:mk(binary(), #{
                desc => ?DESC(deactivate_at),
                example => <<"2021-10-31T10:52:52.548+08:00">>
            })}
    ].

%%%==============================================================================================
%% parameters trans
alarms(get, #{query_string := QString}) ->
    Table =
        case maps:get(<<"activated">>, QString, true) of
            true -> ?ACTIVATED_ALARM;
            false -> ?DEACTIVATED_ALARM
        end,
    case
        emqx_mgmt_api:cluster_query(
            Table,
            QString,
            [],
            fun ?MODULE:qs2ms/2,
            fun ?MODULE:format_alarm/2
        )
    of
        {error, page_limit_invalid} ->
            {400, #{code => <<"INVALID_PARAMETER">>, message => <<"page_limit_invalid">>}};
        {error, Node, Error} ->
            Message = list_to_binary(io_lib:format("bad rpc call ~p, Reason ~p", [Node, Error])),
            {500, #{code => <<"NODE_DOWN">>, message => Message}};
        Response ->
            {200, Response}
    end;
alarms(delete, _Params) ->
    _ = emqx_mgmt:delete_all_deactivated_alarms(),
    {204}.

%%%==============================================================================================
%% internal

-spec qs2ms(atom(), {list(), list()}) -> emqx_mgmt_api:match_spec_and_filter().
qs2ms(_Tab, {_Qs, _Fuzzy}) ->
    #{match_spec => [{'$1', [], ['$1']}], fuzzy_fun => undefined}.

format_alarm(WhichNode, Alarm) ->
    emqx_alarm:format(WhichNode, Alarm).
