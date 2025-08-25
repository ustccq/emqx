%%------------------------------------------------------------------------
%% Copyright (c) 2013-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%------------------------------------------------------------------------

-module(emqx_request_responser_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

init_per_suite(Config) ->
    Apps = emqx_cth_suite:start([emqx], #{work_dir => emqx_cth_suite:work_dir(Config)}),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    emqx_cth_suite:stop(?config(apps, Config)).

all() ->
    emqx_common_test_helpers:all(?MODULE).

t_request_response_qos0(_Config) ->
    request_response_per_qos(?QOS_0).

t_request_response_qos1(_Config) ->
    request_response_per_qos(?QOS_1).

t_request_response_qos2(_Config) ->
    request_response_per_qos(?QOS_2).

request_response_per_qos(QoS) ->
    ReqTopic = <<"request_topic">>,
    RspTopic = <<"response_topic">>,
    {ok, Requester} = emqx_request_sender:start_link(
        RspTopic,
        QoS,
        [
            {proto_ver, v5},
            {clientid, <<"requester">>},
            {properties, #{'Request-Response-Information' => 1}}
        ]
    ),
    %% This is a square service
    Square = fun(_CorrData, ReqBin) ->
        I = b2i(ReqBin),
        i2b(I * I)
    end,
    {ok, Responder} = emqx_request_handler:start_link(
        ReqTopic,
        QoS,
        Square,
        [
            {proto_ver, v5},
            {clientid, <<"responder">>}
        ]
    ),
    ok = emqx_request_sender:send(Requester, ReqTopic, RspTopic, <<"corr-1">>, <<"2">>, QoS),
    receive
        {response, <<"corr-1">>, <<"4">>} ->
            ok;
        Other ->
            erlang:error({unexpected, Other})
    after 100 ->
        erlang:error(timeout)
    end,
    ok = emqx_request_sender:stop(Requester),
    ok = emqx_request_handler:stop(Responder).

b2i(B) -> binary_to_integer(B).
i2b(I) -> integer_to_binary(I).
