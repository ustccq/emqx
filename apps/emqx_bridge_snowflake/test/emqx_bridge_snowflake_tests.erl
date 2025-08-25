%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bridge_snowflake_tests).

-include_lib("eunit/include/eunit.hrl").
-include("src/emqx_bridge_snowflake.hrl").

%%------------------------------------------------------------------------------
%% Helper fns
%%------------------------------------------------------------------------------

-define(CONNECTOR_NAME, <<"my_connector">>).

parse_and_check_connector(InnerConfig) ->
    %% To trigger schema injections
    _ = emqx_conf_schema:roots(),
    emqx_bridge_v2_testlib:parse_and_check_connector(
        ?CONNECTOR_TYPE_AGGREG_BIN,
        ?CONNECTOR_NAME,
        InnerConfig
    ).

connector_config(Overrides) ->
    Base = emqx_bridge_snowflake_aggregated_SUITE:connector_config(
        ?CONNECTOR_NAME,
        <<"orgid-accountid">>,
        <<"orgid-accountid.snowflakecomputing.com">>,
        <<"odbcuser">>,
        <<"odbcpass">>
    ),
    emqx_utils_maps:deep_merge(Base, Overrides).

%%------------------------------------------------------------------------------
%% Test cases
%%------------------------------------------------------------------------------

validation_test_() ->
    [
        {"good config", ?_assertMatch(#{}, parse_and_check_connector(connector_config(#{})))},
        {"account must contain org id and account id",
            ?_assertThrow(
                {_SchemaMod, [
                    #{
                        reason := <<"Account identifier must be of form ORGID-ACCOUNTNAME">>,
                        kind := validation_error
                    }
                ]},
                parse_and_check_connector(
                    connector_config(#{
                        <<"account">> => <<"onlyaccid">>
                    })
                )
            )},
        {"both password and password file defined",
            ?_assertThrow(
                {_SchemaMod, [
                    #{
                        reason := <<
                            "At most one of `password` or `private_key_path`"
                            " must be set, but not both"
                        >>,
                        kind := validation_error
                    }
                ]},
                parse_and_check_connector(
                    connector_config(#{
                        <<"password">> => <<"secret">>,
                        <<"private_key_path">> => <<"also_defined">>
                    })
                )
            )}
    ].
