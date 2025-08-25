%%--------------------------------------------------------------------
%% Copyright (c) 2023-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_rule_engine_schema_tests).

-include_lib("eunit/include/eunit.hrl").

%%===========================================================================
%% Data Section
%%===========================================================================

%% erlfmt-ignore
republish_hocon0() ->
"
rule_engine.rules.my_rule {
  description = \"some desc\"
  metadata = {created_at = 1693918992079}
  sql = \"select * from \\\"t/topic\\\" \"
  actions = [
    {function = console, args = {test = 1}}
    { function = republish
      args = {
        payload = \"${.}\"
        qos = 0
        retain = false
        topic = \"t/repu\"
        mqtt_properties {
          \"Payload-Format-Indicator\" = \"${.payload.pfi}\"
          \"Message-Expiry-Interval\" = \"${.payload.mei}\"
          \"Content-Type\" = \"${.payload.ct}\"
          \"Response-Topic\" = \"${.payload.rt}\"
          \"Correlation-Data\" = \"${.payload.cd}\"
        }
        user_properties = \"${pub_props.'User-Property'}\"
      }
    },
    \"bridges:kafka:kprodu\",
    { function = custom_fn
      args = {
        actually = not_republish
      }
    }
  ]
}
".

%%===========================================================================
%% Helper functions
%%===========================================================================

parse(Hocon) ->
    {ok, Conf} = hocon:binary(Hocon),
    Conf.

check(Conf) when is_map(Conf) ->
    hocon_tconf:check_plain(emqx_rule_engine_schema, Conf).

-define(ok_config(Cfg), #{
    <<"rule_engine">> :=
        #{
            <<"rules">> :=
                #{
                    <<"my_rule">> :=
                        Cfg
                }
        }
}).

%%===========================================================================
%% Test cases
%%===========================================================================

republish_test_() ->
    BaseConf = parse(republish_hocon0()),
    [
        {"base config",
            ?_assertMatch(
                ?ok_config(
                    #{
                        <<"actions">> := [
                            #{<<"function">> := console},
                            #{
                                <<"function">> := republish,
                                <<"args">> :=
                                    #{
                                        <<"mqtt_properties">> :=
                                            #{
                                                <<"Payload-Format-Indicator">> := <<_/binary>>,
                                                <<"Message-Expiry-Interval">> := <<_/binary>>,
                                                <<"Content-Type">> := <<_/binary>>,
                                                <<"Response-Topic">> := <<_/binary>>,
                                                <<"Correlation-Data">> := <<_/binary>>
                                            }
                                    }
                            },
                            <<"bridges:kafka:kprodu">>,
                            #{
                                <<"function">> := <<"custom_fn">>,
                                <<"args">> :=
                                    #{
                                        <<"actually">> := <<"not_republish">>
                                    }
                            }
                        ]
                    }
                ),
                check(BaseConf)
            )}
    ].
