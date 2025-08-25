%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_auto_subscribe_api).

-behaviour(minirest_api).

-export([
    api_spec/0,
    paths/0,
    schema/1
]).

-export([auto_subscribe/2]).

-define(INTERNAL_ERROR, 'INTERNAL_ERROR').
-define(EXCEED_LIMIT, 'EXCEED_LIMIT').

-include_lib("hocon/include/hoconsc.hrl").
-include_lib("emqx/include/emqx_placeholder.hrl").

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true}).

paths() ->
    ["/mqtt/auto_subscribe"].

schema("/mqtt/auto_subscribe") ->
    #{
        'operationId' => auto_subscribe,
        get => #{
            description => ?DESC(list_auto_subscribe_api),
            tags => [<<"Auto Subscribe">>],
            responses => #{
                200 => topics()
            }
        },
        put => #{
            description => ?DESC(update_auto_subscribe_api),
            tags => [<<"Auto Subscribe">>],
            'requestBody' => topics(),
            responses => #{
                200 => topics(),
                409 => emqx_dashboard_swagger:error_codes(
                    [?EXCEED_LIMIT],
                    ?DESC(update_auto_subscribe_api_response409)
                )
            }
        }
    }.

topics() ->
    Fields = emqx_auto_subscribe_schema:fields("auto_subscribe"),
    {topics, Topics} = lists:keyfind(topics, 1, Fields),
    Topics.

%%%==============================================================================================
%% api apply
auto_subscribe(get, _) ->
    {200, emqx_auto_subscribe:list()};
auto_subscribe(put, #{body := Topics}) when is_list(Topics) ->
    case emqx_auto_subscribe:update(Topics) of
        {error, quota_exceeded} ->
            Message = list_to_binary(
                io_lib:format(
                    "Max auto subscribe topic count is  ~p",
                    [emqx_auto_subscribe:max_limit()]
                )
            ),
            {409, #{code => ?EXCEED_LIMIT, message => Message}};
        {error, Reason} ->
            Message = list_to_binary(io_lib:format("Update config failed ~p", [Reason])),
            {500, #{code => ?INTERNAL_ERROR, message => Message}};
        {ok, NewTopics} ->
            {200, NewTopics}
    end.
