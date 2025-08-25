%%--------------------------------------------------------------------
%% Copyright (c) 2018-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_mqtt_props_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> emqx_common_test_helpers:all(?MODULE).

t_id(_) ->
    foreach_prop(
        fun({Id, Prop}) ->
            ?assertEqual(Id, emqx_mqtt_props:id(element(1, Prop)))
        end
    ),
    ?assertError({bad_property, 'Bad-Property'}, emqx_mqtt_props:id('Bad-Property')).

t_name(_) ->
    foreach_prop(
        fun({Id, Prop}) ->
            ?assertEqual(emqx_mqtt_props:name(Id), element(1, Prop))
        end
    ),
    ?assertError({unsupported_property, 16#FF}, emqx_mqtt_props:name(16#FF)).

t_filter(_) ->
    ConnProps = #{
        'Session-Expiry-Interval' => 1,
        'Maximum-Packet-Size' => 255
    },
    ?assertEqual(
        ConnProps,
        emqx_mqtt_props:filter(?CONNECT, ConnProps)
    ),
    PubProps = #{
        'Payload-Format-Indicator' => 6,
        'Message-Expiry-Interval' => 300,
        'Session-Expiry-Interval' => 300
    },
    ?assertEqual(
        #{
            'Payload-Format-Indicator' => 6,
            'Message-Expiry-Interval' => 300
        },
        emqx_mqtt_props:filter(?PUBLISH, PubProps)
    ).

t_validate(_) ->
    ConnProps = #{
        'Session-Expiry-Interval' => 1,
        'Maximum-Packet-Size' => 255
    },
    ok = emqx_mqtt_props:validate(ConnProps),
    BadProps = #{'Unknown-Property' => 10},
    ?assertError(
        {bad_property, 'Unknown-Property'},
        emqx_mqtt_props:validate(BadProps)
    ).

t_validate_value(_) ->
    ok = emqx_mqtt_props:validate(#{'Correlation-Data' => <<"correlation-id">>}),
    ok = emqx_mqtt_props:validate(#{'Reason-String' => <<"Unknown Reason">>}),
    ok = emqx_mqtt_props:validate(#{'User-Property' => {<<"Prop">>, <<"Val">>}}),
    ok = emqx_mqtt_props:validate(#{'User-Property' => [{<<"Prop">>, <<"Val">>}]}),
    ?assertError(
        {bad_property_value, {'Payload-Format-Indicator', 16#FFFF}},
        emqx_mqtt_props:validate(#{'Payload-Format-Indicator' => 16#FFFF})
    ),
    ?assertError(
        {bad_property_value, {'Server-Keep-Alive', 16#FFFFFF}},
        emqx_mqtt_props:validate(#{'Server-Keep-Alive' => 16#FFFFFF})
    ),
    ?assertError(
        {bad_property_value, {'Will-Delay-Interval', -16#FF}},
        emqx_mqtt_props:validate(#{'Will-Delay-Interval' => -16#FF})
    ).

foreach_prop(Fun) ->
    lists:foreach(Fun, maps:to_list(emqx_mqtt_props:all())).

% t_all(_) ->
%     error('TODO').

% t_set(_) ->
%     error('TODO').

% t_get(_) ->
%     error('TODO').
