%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_authz_file_SUITE).

-compile(nowarn_export_all).
-compile(export_all).
-compile(nowarn_update_literal).

-include_lib("emqx_auth/include/emqx_authz.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(RAW_SOURCE, #{
    <<"type">> => <<"file">>,
    <<"enable">> => true,
    <<"rules">> =>
        <<
            "{allow,{username,\"^dashboard?\"},subscribe,[\"$SYS/#\"]}."
            "\n{allow,{ipaddr,\"127.0.0.1\"},all,[\"$SYS/#\",\"#\"]}."
        >>
}).

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

init_per_testcase(TestCase, Config) ->
    Apps = emqx_cth_suite:start(
        [
            {emqx_conf, "authorization.no_match = deny, authorization.cache.enable = false"},
            emqx,
            emqx_auth
        ],
        #{work_dir => filename:join(?config(priv_dir, Config), TestCase)}
    ),
    [{tc_apps, Apps} | Config].

end_per_testcase(_TestCase, Config) ->
    emqx_cth_suite:stop(?config(tc_apps, Config)).

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_ok(_Config) ->
    ClientInfo = emqx_authz_test_lib:base_client_info(),

    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{allow, {user, \"username\"}, publish, [\"t\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH, <<"t">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t">>)
    ).

t_client_attrs(_Config) ->
    ClientInfo0 = emqx_authz_test_lib:base_client_info(),
    ClientInfo = ClientInfo0#{client_attrs => #{<<"device_id">> => <<"id1">>}},

    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{allow, all, all, [\"t/${client_attrs.device_id}/#\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH, <<"t/id1/1">>)
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/id1/#">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/id2/#">>)
    ),
    ok.

t_zone_as_who_condition(_Config) ->
    ClientInfo0 = emqx_authz_test_lib:base_client_info(),
    ClientInfo = ClientInfo0#{zone => zone1},

    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{allow, {zone, zone1}, all, [\"t/1/#\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH, <<"t/1">>)
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/1/#">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo#{zone => ''}, ?AUTHZ_SUBSCRIBE, <<"t/1/#">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/#">>)
    ),
    ok.

t_zone_as_who_condition_re(_Config) ->
    ClientInfo0 = emqx_authz_test_lib:base_client_info(),
    ClientInfo = ClientInfo0#{zone => zone1},

    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{allow, {zone, {re, \"^zone1$\"}}, all, [\"t/1/#\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH, <<"t/1">>)
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/1/#">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo#{zone => zone2}, ?AUTHZ_SUBSCRIBE, <<"t/1/#">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/#">>)
    ),
    ok.

t_listener(_Config) ->
    ClientInfo0 = emqx_authz_test_lib:base_client_info(),
    ClientInfo = ClientInfo0#{listener => 'tcp:a'},

    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{allow, {listener, \"tcp:a\"}, all, [\"t/1/#\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH, <<"t/1">>)
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/1/#">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(
            ClientInfo#{listener => 'ssl:a'}, ?AUTHZ_SUBSCRIBE, <<"t/1/#">>
        )
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/#">>)
    ),
    ok.

t_listener_re(_Config) ->
    ClientInfo0 = emqx_authz_test_lib:base_client_info(),
    ClientInfo = ClientInfo0#{listener => 'tcp:a'},

    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{allow, {listener, {re, \"^tcp:.*\"}}, all, [\"t/1/#\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH, <<"t/1">>)
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/1/#">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(
            ClientInfo#{listener => 'ssl:a'}, ?AUTHZ_SUBSCRIBE, <<"t/1/#">>
        )
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/#">>)
    ),
    ok.

t_cert_common_name(_Config) ->
    ClientInfo0 = emqx_authz_test_lib:base_client_info(),
    ClientInfo = ClientInfo0#{cn => <<"mycn">>},
    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{allow, all, all, [\"t/${cert_common_name}/#\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH, <<"t/mycn/1">>)
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/mycn/#">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/othercn/1">>)
    ),
    ok.

t_zone_in_topic_template(_Config) ->
    ClientInfo0 = emqx_authz_test_lib:base_client_info(),
    ClientInfo = ClientInfo0#{zone => <<"zone1">>},
    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{allow, all, all, [\"t/${zone}/#\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH, <<"t/zone1/1">>)
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/zone1/#">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo#{zone => other}, ?AUTHZ_SUBSCRIBE, <<"t/zone1/1">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t/otherzone/1">>)
    ),
    ok.

t_extended_actions(_Config) ->
    ClientInfo = emqx_authz_test_lib:base_client_info(),

    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> =>
            <<"{allow, {user, \"username\"}, {publish, [{qos, 1}, {retain, false}]}, [\"t\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH(1, false), <<"t">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH(0, false), <<"t">>)
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t">>)
    ).

t_superuser(_Config) ->
    ClientInfo =
        emqx_authz_test_lib:client_info(#{is_superuser => true}),

    %% no rules apply to superuser
    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{deny, {user, \"username\"}, publish, [\"t\"]}.">>
    }),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_PUBLISH, <<"t">>)
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, ?AUTHZ_SUBSCRIBE, <<"t">>)
    ).

t_invalid_file(_Config) ->
    ?assertMatch(
        {error,
            {pre_config_update, emqx_authz,
                {bad_acl_file_content, {1, erl_parse, ["syntax error before: ", "term"]}}}},
        emqx_authz:update(?CMD_REPLACE, [?RAW_SOURCE#{<<"rules">> => <<"{{invalid term">>}])
    ).

t_update(_Config) ->
    ok = setup_config(?RAW_SOURCE#{
        <<"rules">> => <<"{allow, {user, \"username\"}, publish, [\"t\"]}.">>
    }),

    ?assertMatch(
        {error, _},
        emqx_authz:update(
            {?CMD_REPLACE, file},
            ?RAW_SOURCE#{<<"rules">> => <<"{{invalid term">>}
        )
    ),

    ?assertMatch(
        {ok, _},
        emqx_authz:update(
            {?CMD_REPLACE, file}, ?RAW_SOURCE
        )
    ).

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

setup_config(SpecialParams) ->
    emqx_authz_test_lib:setup_config(
        ?RAW_SOURCE,
        SpecialParams
    ).

stop_apps(Apps) ->
    lists:foreach(fun application:stop/1, Apps).
